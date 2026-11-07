#!/usr/bin/env python3
"""Build the prepared standalone app on macOS; never sign, install on hardware or flash."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import zipfile

from standalone_prepare import BUNDLE_ID, BUILD_MARKER, UPSTREAM_COMMIT, file_records, sha256, tree_hash, write_json


class Builder:
    def __init__(self, prepared: Path, artifacts: Path):
        self.prepared = prepared
        self.source = prepared / "source"
        self.artifacts = artifacts
        if artifacts.exists() and any(artifacts.iterdir()):
            raise ValueError("Artifact output must be new or empty")
        self.reports = artifacts / "reports"
        self.reports.mkdir(parents=True, exist_ok=True)
        self.report = {"schemaVersion": 1, "marker": BUILD_MARKER, "success": False,
                       "physicalDeviceValidated": False, "steps": [], "screenshots": []}

    def run(self, label: str, args: list[str], *, timeout: int = 900, required: bool = True) -> str:
        print(f"[{label}] starting", flush=True)
        path = self.reports / (label + ".log")
        started = time.monotonic()
        code = None
        try:
            with path.open("w", encoding="utf-8") as log:
                log.write("Command: " + json.dumps(args, ensure_ascii=False) + "\n")
                log.flush()
                process = subprocess.run(args, cwd=self.source, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
                code = process.returncode
        finally:
            self.report["steps"].append({"name": label, "exitCode": code, "seconds": round(time.monotonic() - started, 2), "required": required})
            self.save_report()
        text = path.read_text(encoding="utf-8", errors="replace")
        # The first line is our command, not tool output.
        output = text.partition("\n")[2]
        if code != 0:
            diagnostics = [line for line in output.splitlines()
                           if re.search(r"\.(swift|m|mm|c|h):\d+:.*(?:error|warning):", line)]
            if diagnostics:
                print("\n".join(diagnostics[-30:]), flush=True)
            print(output[-8000:], flush=True)
            if required:
                raise RuntimeError(f"{label} failed; see reports/{label}.log")
        print(f"[{label}] exit={code}", flush=True)
        return output

    def save_report(self) -> None:
        write_json(self.reports / "build-report.json", self.report)

    def verify_prepared(self) -> dict:
        manifest = json.loads((self.prepared / "preparation-manifest.json").read_text(encoding="utf-8"))
        if manifest.get("upstreamCommit") != UPSTREAM_COMMIT or manifest.get("bundleIdentifier") != BUNDLE_ID:
            raise ValueError("Prepared build identity mismatch")
        if tree_hash(file_records(self.source)) != manifest["sourceTreeSHA256"]:
            raise ValueError("Prepared source tree changed after hashing")
        shutil.copyfile(self.prepared / "preparation-manifest.json", self.artifacts / "preparation-manifest.json")
        legal = self.artifacts / "licenses"
        legal.mkdir()
        for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
            shutil.copyfile(self.source / name, legal / name)
        self.report["upstreamCommit"] = UPSTREAM_COMMIT
        self.report["recipeCommit"] = manifest["recipeCommit"]
        self.report["preparedSourceTreeSHA256"] = manifest["sourceTreeSHA256"]
        return manifest

    def simulator(self) -> str:
        data = json.loads(self.run("simulator-list", ["xcrun", "simctl", "list", "devices", "available", "--json"]))
        candidates = []
        for runtime, devices in data["devices"].items():
            if ".iOS-" not in runtime:
                continue
            for device in devices:
                if device.get("isAvailable") and device["name"].startswith("iPhone"):
                    version = tuple(int(n) for n in runtime.rsplit("iOS-", 1)[1].split("-"))
                    candidates.append((version, "Pro Max" in device["name"], device["name"], device))
        if not candidates:
            raise RuntimeError("No available iPhone simulator runtime")
        _, _, name, device = max(candidates, key=lambda row: row[:3])
        udid = device["udid"]
        self.report["simulator"] = {"name": name, "udid": udid}
        if device["state"] != "Booted":
            self.run("simulator-boot", ["xcrun", "simctl", "boot", udid], timeout=90)
        self.run("simulator-bootstatus", ["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=180)
        return udid

    def screenshots(self, udid: str, app: Path) -> None:
        destination = self.artifacts / "screenshots"
        destination.mkdir()
        try:
            self.run("screenshot-install-simulator", ["xcrun", "simctl", "install", udid, str(app)], timeout=90)
            for tab, name in enumerate(("dashboard", "ai", "navigation", "notebooks", "settings")):
                self.run(f"screenshot-terminate-{tab}", ["xcrun", "simctl", "terminate", udid, BUNDLE_ID], timeout=30, required=False)
                self.run(f"screenshot-launch-{tab}", ["xcrun", "simctl", "launch", udid, BUNDLE_ID, "--io-tab", str(tab)], timeout=45)
                time.sleep(3)
                path = destination / f"{tab}-{name}.png"
                self.run(f"screenshot-capture-{tab}", ["xcrun", "simctl", "io", udid, "screenshot", str(path)], timeout=30)
                self.report["screenshots"].append({"tab": tab, "path": path.relative_to(self.artifacts).as_posix(), "sha256": sha256(path), "evidence": "simulator-only; not physical-device acceptance"})
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            self.report["screenshotFailure"] = str(error)
            print("Optional simulator screenshots incomplete: " + str(error), flush=True)
        finally:
            self.save_report()

    def package(self, app: Path) -> dict:
        if not app.is_dir():
            raise RuntimeError("Release app bundle not found")
        info = plistlib.loads((app / "Info.plist").read_bytes())
        expected = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleDisplayName": "IO伴侣", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}
        for key, value in expected.items():
            if info.get(key) != value:
                raise RuntimeError(f"Unexpected built app metadata: {key}")
        executable = app / info["CFBundleExecutable"]
        archs = self.run("device-architecture", ["xcrun", "lipo", "-archs", str(executable)], timeout=30).strip()
        if archs != "arm64":
            raise RuntimeError("Expected arm64-only device build")
        names = {p.stem for p in (app / "Frameworks").glob("*.framework")}
        expected_frameworks = {"RayneoNet", "CocoaAsyncSocket", "OpenSSL", "RayneoLog", "SwiftProtobuf", "CocoaLumberjack", "SSZipArchive"}
        if not expected_frameworks.issubset(names):
            raise RuntimeError("Missing embedded device framework")
        ipa = self.artifacts / "IOCompanion-0.1.0-dev01-unsigned.ipa"
        # Only the built application is archived. Preserve modes; omit stale signature metadata.
        with zipfile.ZipFile(ipa, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(app.rglob("*")):
                relative = path.relative_to(app)
                if "_CodeSignature" in relative.parts or path.name == "embedded.mobileprovision":
                    continue
                if path.is_symlink():
                    raise ValueError("Unexpected app symlink; refusing to follow it into the package")
                if path.is_file():
                    archive.write(path, "Payload/" + app.name + "/" + relative.as_posix())
        with zipfile.ZipFile(ipa) as archive:
            if archive.testzip() is not None:
                raise RuntimeError("IPA ZIP validation failed")
        digest = sha256(ipa)
        (self.artifacts / (ipa.name + ".sha256")).write_text(digest + "  " + ipa.name + "\n", encoding="utf-8")
        return {"path": ipa.name, "bytes": ipa.stat().st_size, "sha256": digest, "architecture": archs,
                "signing": "unsigned main app; all executable bundles require local re-signing", "physicalDeviceValidated": False}

    def build(self, screenshots: bool) -> None:
        manifest = self.verify_prepared()
        self.report["startedAtUTC"] = datetime.now(timezone.utc).isoformat()
        self.report["tools"] = {
            "xcode": self.run("xcode-version", ["xcodebuild", "-version"]).strip(),
            "xcodegen": self.run("xcodegen-version", ["xcodegen", "--version"]).strip(),
            "swift": self.run("swift-version", ["xcrun", "swiftc", "--version"]).strip(),
            "python": sys.version,
        }
        native = self.prepared / "native-tests"
        native.mkdir()
        self.run("dashboard-test-compile", ["xcrun", "swiftc", "-D", "IO_DASHBOARD_LOGIC_TEST",
            str(self.source / "apps/RayNeoCompanion/Sources/IODashboard.swift"),
            str(self.source / "apps/RayNeoCompanion/CompanionNativeTests/IODashboardTests.swift"),
            "-o", str(native / "io-dashboard-tests")], timeout=120)
        self.run("dashboard-tests", [str(native / "io-dashboard-tests")], timeout=60)
        sdk = self.run("iphoneos-sdk", ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
        module = self.source / "core-probe/RecoveredInterface/build/RayneoNet.swiftmodule"
        module.mkdir(parents=True, exist_ok=True)
        # Declarations only: no -c/-emit-library, object file or placeholder implementation linkage.
        self.run("recovered-declaration-module", ["xcrun", "swiftc", "-emit-module", "-parse-as-library",
            "-module-name", "RayneoNet", "-target", "arm64-apple-ios16.0", "-sdk", sdk,
            "core-probe/RecoveredInterface/RayneoNet.swift", "-emit-module-path", str(module / "arm64-apple-ios.swiftmodule")], timeout=180)
        self.run("xcodegen", ["xcodegen", "generate", "--spec", "apps/RayNeoCompanion/project-device.yml"], timeout=90)
        project = str(self.source / "apps/RayNeoCompanion/RayNeoCompanion.xcodeproj")
        simulator = self.simulator()
        sim_derived = self.prepared / "derived-simulator"
        result = self.prepared / "unit-tests.xcresult"
        self.run("simulator-unit-tests", ["xcodebuild", "test", "-project", project, "-scheme", "RayNeoCompanion",
            "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + simulator,
            "-derivedDataPath", str(sim_derived), "-resultBundlePath", str(result),
            "-only-testing:RayNeoCompanionTests", "-parallel-testing-enabled", "NO",
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="], timeout=1100)
        summary = self.run("simulator-test-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], timeout=60, required=False)
        try:
            write_json(self.reports / "simulator-test-summary.json", json.loads(summary))
        except json.JSONDecodeError:
            self.report["testSummaryNote"] = "Compact xcresult export unavailable; successful xcodebuild test log retained."
        if screenshots:
            self.screenshots(simulator, sim_derived / "Build/Products/Debug-iphonesimulator/RayNeoCompanion.app")
        device_derived = self.prepared / "derived-device"
        self.run("device-unsigned-release", ["xcodebuild", "build", "-project", project,
            "-scheme", "RayNeoCompanionDevice", "-configuration", "Release", "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS", "-derivedDataPath", str(device_derived),
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "ARCHS=arm64"], timeout=900)
        package = self.package(device_derived / "Build/Products/Release-iphoneos/RayNeoCompanion.app")
        manifest["validation"] = {"sourcePrepared": True, "compiled": True, "simulatorTests": "passed",
                                  "dashboardNativeTests": "passed", "physicalDeviceValidated": False}
        manifest["package"] = package
        manifest["tools"] = self.report["tools"]
        manifest["builtAtUTC"] = datetime.now(timezone.utc).isoformat()
        write_json(self.artifacts / "build-manifest.json", manifest)
        self.report["package"] = package
        self.report["success"] = True
        self.report["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
        self.save_report()
        print("Unsigned independent app ready; no physical iPhone or glasses acceptance has been performed.", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", type=Path, default=Path("build/standalone"))
    parser.add_argument("--artifacts", type=Path, default=Path("artifact/standalone"))
    parser.add_argument("--skip-screenshots", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native builds require macOS; standalone_prepare.py can run on Windows")
    builder = Builder(args.prepared.resolve(), args.artifacts.resolve())
    try:
        builder.build(screenshots=not args.skip_screenshots)
    except Exception as error:
        builder.report["error"] = str(error)
        builder.save_report()
        raise


if __name__ == "__main__":
    main()
