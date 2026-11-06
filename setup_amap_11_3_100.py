"""Install the explicitly reviewed 2026-11-06 AMap pins, without an API key.

This is a named SDK upgrade from upstream's 11.2.100/1.9.1 fetcher.
Changing an upstream URL's contents always fails the fixed hash checks.
"""
import argparse
import hashlib
import io
import json
import os
import re
import stat
import urllib.request
import zipfile
from pathlib import Path
from amap_support import (ARCHIVES, FRAMEWORKS, FRAMEWORK_SHA256, RESOURCES, VERSIONS, digest,
                          inventory, no_links, require, safe_relative, tree_digest, validate_resource_evidence)

INNER = {
    'navi': ('AMap_iOS_Navi_ALL/AMap_iOS_Navi_Lib_V11.3.100.zip',
             'b6704b432c0b6f9618c8e60d5ac82123b1715ea601bf8e1e0432057836713930'),
    'foundation': ('AMap_iOS_Navi_ALL/AMap_iOS_Foundation_Lib_V1.9.4_20260904.zip',
                   'd89ea0f271b49f63ad0b976e9bc4af25cb3b2c2896764d547af0729a903ce39a'),
}


def obtain(archives):
    archives.mkdir(parents=True, exist_ok=True)
    no_links(archives)
    for name, pin in ARCHIVES.items():
        path = archives / name
        if not path.exists():
            with urllib.request.urlopen(pin['url'], timeout=60) as incoming:
                require(incoming.url.startswith('https://a.amap.com/'), 'amap_unexpected_download_redirect')
                with path.open('xb') as output:
                    total = 0
                    while chunk := incoming.read(1024 * 1024):
                        total += len(chunk)
                        require(total <= pin['bytes'], 'amap_archive_size_changed')
                        output.write(chunk)
        no_links(path)
        require(path.stat().st_size == pin['bytes'] and digest(path) == pin['sha256'],
                'amap_pinned_archive_mismatch_' + name)


def extract_framework(archive, framework, destination):
    """Extract only the selected framework, never using ZipFile.extractall."""
    entries, cases, total = [], set(), 0
    for entry in archive.infolist():
        name = entry.filename.rstrip('/')
        if not name or '__MACOSX' in name.split('/'):
            continue
        safe_relative(name)
        if not name.startswith(framework + '/'):
            continue
        relative = name[len(framework) + 1:]
        safe_relative(relative)
        require(relative.casefold() not in cases, 'amap_duplicate_archive_path')
        cases.add(relative.casefold())
        mode = entry.external_attr >> 16
        require(not stat.S_ISLNK(mode), 'amap_symlink_in_archive')
        if entry.is_dir():
            continue
        require(stat.S_IFMT(mode) in (0, stat.S_IFREG), 'amap_special_archive_member')
        total += entry.file_size
        require(total < 700 * 1024 * 1024 and len(entries) < 30000, 'amap_archive_expanded_limit')
        entries.append((entry, relative))
    require(entries, 'amap_framework_missing_' + framework)
    destination.mkdir(parents=True, exist_ok=False)
    for entry, relative in entries:
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        no_links(output.parent)
        with archive.open(entry) as source, output.open('xb') as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)


def install(sdk_root, archives):
    sdk_root = Path(os.path.abspath(sdk_root))
    require(not sdk_root.exists(), 'amap_sdk_destination_exists')
    sdk_root.parent.mkdir(parents=True, exist_ok=True)
    no_links(sdk_root.parent)
    obtain(archives)
    # All network bytes and nested archive pins are checked before extraction.
    nested = {}
    with zipfile.ZipFile(archives / 'AMap_iOS_Navi_ALL.zip') as outer:
        for part, (name, sha) in INNER.items():
            require(outer.namelist().count(name) == 1, 'amap_nested_archive_missing_or_duplicate')
            content = outer.read(name)
            require(hashlib.sha256(content).hexdigest() == sha, 'amap_nested_archive_hash_changed')
            nested[part] = content
    sdk_root.mkdir(exist_ok=False)
    for part, content in nested.items():
        framework = 'AMapNaviKit.framework' if part == 'navi' else 'AMapFoundationKit.framework'
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            extract_framework(archive, framework, sdk_root / part / framework)
    with zipfile.ZipFile(archives / 'search-9.8.1.zip') as archive:
        extract_framework(archive, 'AMapSearchKit.framework', sdk_root / 'search/AMapSearchKit.framework')
    frameworks = {}
    for relative, (binary, header, macro, number) in FRAMEWORKS.items():
        folder = sdk_root / relative
        header_text = (folder / 'Headers' / header).read_text(encoding='utf-8', errors='replace')
        match = re.search(r'^\s*#\s*define\s+' + re.escape(macro) + r'\s+(\d+)\b', header_text, re.M)
        require(match and int(match[1]) == number, 'amap_sdk_header_version_mismatch_' + binary)
        frameworks[relative] = {'bytes': (folder / binary).stat().st_size,
                               'sha256': digest(folder / binary),
                               'versionMacro': macro, 'versionNumber': number}
        require(frameworks[relative]['sha256'] == FRAMEWORK_SHA256[relative],
                'amap_framework_pin_mismatch_' + binary)
    resources = {}
    for name, relative in RESOURCES.items():
        files = inventory(sdk_root / relative)
        resources[name] = {'files': files, 'treeSHA256': tree_digest(files)}
    evidence = dict(format='TurboIO-AMap-SDK-1', versions=VERSIONS, archives=ARCHIVES,
                    nestedArchives={part: {'path': name, 'sha256': sha} for part, (name, sha) in INNER.items()},
                    frameworks=frameworks, resources=resources,
                    setupScriptSHA256=digest(__file__), apiKeyConfigured=False,
                    navigationRuntimeValidated=False,
                    termsURL='https://lbs.amap.com/pages/terms/',
                    privacyURL='https://lbs.amap.com/pages/privacy/',
                    downloadURL='https://lbs.amap.com/api/ios-navi-sdk/download')
    validate_resource_evidence(evidence)
    (sdk_root / 'sdk-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'versions': VERSIONS, 'frameworks': frameworks,
                      'resourceFiles': {name: len(item['files']) for name, item in resources.items()},
                      'apiKeyConfigured': False, 'navigationRuntimeValidated': False}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk-root', type=Path, required=True)
    parser.add_argument('--archives-dir', type=Path, default=Path('build/amap-11.3.100-inputs'))
    parser.add_argument('--accept-sdk-terms', action='store_true')
    args = parser.parse_args()
    require(args.accept_sdk_terms, 'read_sdk_terms_before_using_accept_sdk_terms')
    install(args.sdk_root, args.archives_dir)
