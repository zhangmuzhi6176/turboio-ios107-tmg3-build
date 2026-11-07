#!/usr/bin/env python3
"""Export and prepare the pinned, independent companion app. Standard library only."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
from datetime import datetime, timezone

UPSTREAM_COMMIT = "f983669a2db1c2a658f7d4c50285b81aa074345a"
UPSTREAM_URL = "https://github.com/Turbo1123/Turbo-IO.git"
BUNDLE_ID = "com.leo.iocompanion"
BUILD_MARKER = "IO-COMPANION-DEV01"
EXPORT_PATHS = (
    "apps/RayNeoCompanion", "core-probe/Sources", "core-probe/Frameworks",
    "core-probe/RecoveredInterface", "core-probe/Vendor", "rayneo-protocol",
    "rayneo-display", "rayneo-session", "rayneo-archive", "rayneo-audio-container",
    "third-party", "DEPENDENCIES.json", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md",
)
OVERRIDES = (
    "RayNeoCompanionApp.swift", "IOCompanionRoot.swift", "IODashboard.swift",
    "IONotebook.swift", "IOConversationRecord.swift",
)
XCTEST_FILES = ("IONotebookTests.swift", "IOConversationRecordTests.swift")
NATIVE_TEST_FILES = ("IODashboardTests.swift",)
NAMESPACE_MAP = {
    "io.turboio.companion": BUNDLE_ID,
    "io.turboio.codex": BUNDLE_ID + ".codex",
    "RayNeo.CloudASR.https.": BUNDLE_ID + ".cloudASR.https.",
    "RayNeo.CloudLLM.https.api.deepseek.com.chat.completions": BUNDLE_ID + ".cloudLLM.https.api.deepseek.com.chat.completions",
    "turboio.cloudASR.host.v1": BUNDLE_ID + ".cloudASR.host.v1",
}
EXPECTED_NAMESPACE_COUNTS = {
    "io.turboio.companion": 5, "io.turboio.codex": 2,
    "RayNeo.CloudASR.https.": 1,
    "RayNeo.CloudLLM.https.api.deepseek.com.chat.completions": 1,
    "turboio.cloudASR.host.v1": 1,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-c", "safe.directory=" + repo.as_posix(), "-C", str(repo), *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return result.stdout.decode("utf-8").strip()


def relative_path(root: Path, name: str) -> Path:
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(p in ("", ".", "..") for p in path.parts) or "\\" in name:
        raise ValueError("Unsafe relative path in source metadata")
    target = root.joinpath(*path.parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError("Source path escapes destination")
    return target


def replace_exact(text: str, old: str, new: str, count: int, label: str) -> str:
    found = text.count(old)
    if found != count:
        raise ValueError(f"Pinned source mismatch for {label}: expected {count}, found {found}")
    return text.replace(old, new)


def write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def file_records(root: Path) -> list[dict]:
    records = []
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix()):
        if path.is_symlink():
            raise ValueError("Unexpected source symlink: " + path.relative_to(root).as_posix())
        if path.is_file():
            records.append({"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": sha256(path)})
    return records


def tree_hash(records: list[dict]) -> str:
    return hashlib.sha256(json.dumps(records, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def verify_dependencies(source: Path) -> dict:
    manifest_path = source / "DEPENDENCIES.json"
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = data.get("files")
    if not isinstance(entries, list) or not entries:
        raise ValueError("DEPENDENCIES.json has no file inventory")
    seen = set()
    for row in entries:
        name = row["path"]
        if name in seen:
            raise ValueError("Duplicate dependency record")
        seen.add(name)
        path = relative_path(source, name)
        if not path.is_file() or path.is_symlink():
            raise ValueError("Missing or unsafe dependency: " + name)
        if type(row["bytes"]) is not int or path.stat().st_size != row["bytes"]:
            raise ValueError("Dependency size mismatch: " + name)
        if not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]) or sha256(path) != row["sha256"]:
            raise ValueError("Dependency SHA-256 mismatch: " + name)
    return {"verifiedFiles": len(entries), "manifestSHA256": sha256(manifest_path), "allSizesAndHashesMatched": True}


def export_source(upstream: Path, output: Path) -> Path:
    if git(upstream, "rev-parse", "HEAD") != UPSTREAM_COMMIT:
        raise ValueError("Upstream checkout is not the required fixed commit")
    source = output / "source"
    if source.exists():
        raise ValueError("Destination source already exists; choose a new output directory")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "upstream-export.tar"
    if archive.exists():
        raise ValueError("An earlier source export exists; choose a new output directory")
    subprocess.run([
        "git", "-c", "safe.directory=" + upstream.as_posix(),
        "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-C", str(upstream),
        "archive", "--format=tar", "--output=" + str(archive), UPSTREAM_COMMIT, *EXPORT_PATHS,
    ], check=True)
    source.mkdir()
    # Only regular files/directories are accepted; no extractall or link traversal.
    with tarfile.open(archive, "r:") as tar:
        for member in tar:
            target = relative_path(source, member.name.rstrip("/"))
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                if target.exists():
                    raise ValueError("Duplicate archived source path")
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = tar.extractfile(member)
                if stream is None:
                    raise ValueError("Unreadable source archive member")
                with stream, target.open("xb") as dest:
                    shutil.copyfileobj(stream, dest)
                os.chmod(target, member.mode & 0o777)
            else:
                raise ValueError("Unsupported archived member type")
    archive.unlink()
    return source


def patch_namespaces(source: Path) -> list[dict]:
    changed = []
    totals = {key: 0 for key in NAMESPACE_MAP}
    for base in (source / "apps/RayNeoCompanion", source / "core-probe/Sources"):
        for path in sorted(base.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            original = text
            counts = {}
            for old, new in NAMESPACE_MAP.items():
                count = text.count(old)
                if count:
                    totals[old] += count
                    counts[old] = count
                    text = text.replace(old, new)
            if text != original:
                path.write_text(text, encoding="utf-8", newline="\n")
                changed.append({"path": path.relative_to(source).as_posix(), "replacements": counts})
    if totals != EXPECTED_NAMESPACE_COUNTS:
        raise ValueError("Pinned keychain/identity namespace counts changed: " + json.dumps(totals))
    return changed


def patch_device_spec(source: Path) -> None:
    path = source / "apps/RayNeoCompanion/project-device.yml"
    text = path.read_text(encoding="utf-8")
    for old, new, count, label in (
        ("bundleIdPrefix: io.turboio", "bundleIdPrefix: com.leo", 1, "bundle prefix"),
        ("io.turboio.companion", BUNDLE_ID, 4, "target bundle identifiers"),
        ("CFBundleDisplayName: Turbo IO", "CFBundleDisplayName: IO伴侣", 2, "display names"),
        ('MARKETING_VERSION: "0.2.0"', 'MARKETING_VERSION: "0.1.0"', 2, "marketing versions"),
        ('CURRENT_PROJECT_VERSION: "2"', 'CURRENT_PROJECT_VERSION: "1"', 2, "build versions"),
        ("        PRODUCT_NAME: RayNeoCompanion\n        GENERATE_INFOPLIST_FILE", "        PRODUCT_NAME: RayNeoCompanion\n        PRODUCT_MODULE_NAME: RayNeoCompanion\n        GENERATE_INFOPLIST_FILE", 1, "simulator module name"),
        ("      targets: [RayNeoCompanionTests, RayNeoCompanionUITests]", "      targets: [RayNeoCompanionTests]", 1, "unit tests only"),
        ("      - Sources\n", "      - Sources\n      - path: IOCompanionLegal\n        buildPhase: resources\n", 2, "legal resource inclusion"),
        ("      properties:\n", "      properties:\n        NSLocationWhenInUseUsageDescription: 在你手动开启时读取当前位置，用于显示实测速度和海拔。\n", 2, "foreground location permission"),
    ):
        text = replace_exact(text, old, new, count, label)
    text = text.replace("为Turbo IO本机待办", "为IO伴侣本机待办").replace("Turbo IO仅执行读取", "IO伴侣仅执行读取")
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_explicit_voice_start(source: Path) -> None:
    path = source / "core-probe/Sources/App.swift"
    text = path.read_text(encoding="utf-8")
    text = replace_exact(text,
        "        voiceProbe.setCloudMode(UserDefaults.standard.bool(forKey:CloudVoiceKeys.enabledKey) && CloudVoiceKeys.ready)",
        "        voiceProbe.setCloudMode(false) // IOCompanion: enabled only by an explicit user action.",
        1, "initial cloud mode")
    text = replace_exact(text,
        "            self?.restoreStandbyIfRequested()",
        "            // IOCompanion: never restore voice standby implicitly on launch.",
        1, "launch standby restoration")
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_current_deepseek_model(source: Path) -> None:
    path = source / "core-probe/Sources/CloudVoicePipeline.swift"
    text = replace_exact(path.read_text(encoding="utf-8"),
        '"model":"deepseek-v4-flash"', '"model":"deepseek-flash"', 1, "DeepSeek model identifier")
    path.write_text(text, encoding="utf-8", newline="\n")


def prepare(upstream: Path, output: Path, recipe: Path) -> dict:
    # Validate our small input set before exporting the upstream tree.
    for folder, expected in (("companion-overrides", OVERRIDES), ("companion-tests", XCTEST_FILES + NATIVE_TEST_FILES)):
        actual = {p.name for p in (recipe / folder).glob("*.swift")}
        if actual != set(expected):
            raise ValueError(f"Unexpected {folder} inventory: expected {sorted(expected)}, found {sorted(actual)}")
    source = export_source(upstream, output)
    dependencies = verify_dependencies(source)
    namespace_changes = patch_namespaces(source)
    app = source / "apps/RayNeoCompanion"
    for name in OVERRIDES:
        shutil.copyfile(recipe / "companion-overrides" / name, app / "Sources" / name)
    for name in XCTEST_FILES:
        shutil.copyfile(recipe / "companion-tests" / name, app / "Tests" / name)
    native = app / "CompanionNativeTests"
    native.mkdir()
    for name in NATIVE_TEST_FILES:
        shutil.copyfile(recipe / "companion-tests" / name, native / name)
    legal = app / "IOCompanionLegal"
    legal.mkdir()
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
        shutil.copyfile(source / name, legal / name)
    patch_device_spec(source)
    patch_explicit_voice_start(source)
    patch_current_deepseek_model(source)
    records = file_records(source)
    prohibited = [r["path"] for r in records if r["path"].lower().endswith((".ipa", ".mobileprovision", ".p12")) or r["path"].startswith(("official-apps/", "firmware-research/", "official-addon/"))]
    if prohibited:
        raise ValueError("Unexpected official-app, firmware or signing input in independent source export")
    recipe_paths = [recipe / name for name in ("standalone_prepare.py", "standalone_build.py", ".github/workflows/standalone.yml")]
    recipe_paths += [recipe / "companion-overrides" / name for name in OVERRIDES]
    recipe_paths += [recipe / "companion-tests" / name for name in XCTEST_FILES + NATIVE_TEST_FILES]
    manifest = {
        "schemaVersion": 1, "marker": BUILD_MARKER, "preparedAtUTC": datetime.now(timezone.utc).isoformat(),
        "upstreamRepository": UPSTREAM_URL, "upstreamCommit": UPSTREAM_COMMIT,
        "recipeCommit": git(recipe, "rev-parse", "HEAD"), "recipeWorkingTreeDirty": bool(git(recipe, "status", "--porcelain")),
        "bundleIdentifier": BUNDLE_ID, "displayName": "IO伴侣", "marketingVersion": "0.1.0", "buildVersion": "1",
        "swiftModule": "RayNeoCompanion", "dependencyVerification": dependencies,
        "namespaceMap": NAMESPACE_MAP, "namespaceChanges": namespace_changes,
        "targetedPatches": [
            {"path": "core-probe/Sources/App.swift", "operation": "disable initial cloud mode", "count": 1},
            {"path": "core-probe/Sources/App.swift", "operation": "remove complete launch restoreStandbyIfRequested call", "count": 1},
            {"path": "core-probe/Sources/CloudVoicePipeline.swift", "operation": "deepseek-v4-flash to deepseek-flash", "count": 1,
             "reference": "https://api-docs.deepseek.com/updates/"},
        ],
        "sourceTreeSHA256": tree_hash(records), "sourceFiles": records,
        "recipeFiles": [{"path": p.relative_to(recipe).as_posix(), "bytes": p.stat().st_size, "sha256": sha256(p)} for p in recipe_paths],
        "validation": {"sourcePrepared": True, "compiled": False, "simulatorTests": "not-run", "physicalDeviceValidated": False},
        "boundaries": ["Independent application; no official IPA input", "No firmware image input or firmware operation", "No automatic pairing or voice activation from the root UI", "Unsigned build requires local signing before installation", "Build and simulator checks do not establish glasses compatibility"],
    }
    write_json(output / "preparation-manifest.json", manifest)
    print(f"Prepared {len(records)} files; verified {dependencies['verifiedFiles']} dependency hashes.")
    print(f"Source tree SHA-256: {manifest['sourceTreeSHA256']}")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/standalone"))
    args = parser.parse_args()
    prepare(args.upstream.resolve(), args.output.resolve(), Path(__file__).resolve().parent)


if __name__ == "__main__":
    main()
