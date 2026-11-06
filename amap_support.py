"""Pinned AMap 11.3.100 resource inventory and fail-closed cross-platform copying.

No account, API key, device connection, signing or firmware operation is used.
"""
import hashlib
import json
import os
import re
import stat
from pathlib import Path, PurePosixPath

VERSIONS = {'navigation': '11.3.100', 'foundation': '1.9.4', 'search': '9.8.1'}
ARCHIVES = {
    'AMap_iOS_Navi_ALL.zip': {
        'url': 'https://a.amap.com/lbs/static/zip/AMap_iOS_Navi_ALL.zip',
        'sha256': '8264377eb68d414c046be96585957250cda15a7eabd16553842f53f98764f4b8',
        'bytes': 271877786,
    },
    'search-9.8.1.zip': {
        'url': 'https://a.amap.com/lbs/static/zip/AMap_iOS_Search_Lib_V9.8.1.zip',
        'sha256': 'd11e0b418319c74abf5228611f678b58130eac791e267d6d6e3e7ec9f41b2007',
        'bytes': 768715,
    },
}
FRAMEWORKS = {
    'navi/AMapNaviKit.framework': ('AMapNaviKit', 'AMapNaviVersion.h', 'AMapNaviVersionNumber', 11030100),
    'foundation/AMapFoundationKit.framework': ('AMapFoundationKit', 'AMapFoundationVersion.h', 'AMapFoundationVersionNumber', 10904),
    'search/AMapSearchKit.framework': ('AMapSearchKit', 'AMapSearchVersion.h', 'AMapSearchVersionNumber', 90801),
}
RESOURCES = {
    'AMap.bundle': 'navi/AMapNaviKit.framework/AMap.bundle',
    'AMapNavi.bundle': 'navi/AMapNaviKit.framework/AMapNavi.bundle',
    'AMapSearch.bundle': 'search/AMapSearchKit.framework/AMapSearch.bundle',
}
# Independently derived from the verified official archives above. A changed
# resource plus a rewritten artifact manifest must not become a valid package.
RESOURCE_TREE_SHA256 = {
    'AMap.bundle': 'c2c2e4295bf4db292459a7bcc51ae382350841a30c699ea366c99d8347a9259a',
    'AMapNavi.bundle': 'feb908b464cda1a2de279aa157e940928d65687a3bb1fcb4befefadaf53ec972',
    'AMapSearch.bundle': '9eaa25e48ae0338629c9b009339f81698c0279833c05fd98fa58154013b1251c',
}
FRAMEWORK_SHA256 = {
    'navi/AMapNaviKit.framework': '7e23cbfc5473e0d51a6a1c312367b20743075a9f4a69e104fc78b50b1c78ac3e',
    'foundation/AMapFoundationKit.framework': '5622a7cd6115eea4d1afc23a67308a30f7828c16250be6cf4915985dd4379727',
    'search/AMapSearchKit.framework': '4ecb3483a26ed13387204a0f4020dcf4b3d85736c8e30ebf4897e818c5ba7962',
}
LINKED_SYMBOLS = (
    '_OBJC_CLASS_$_AMapNaviDriveManager', '_OBJC_CLASS_$_AMapNaviWalkManager',
    '_OBJC_CLASS_$_AMapNaviRideManager', '_OBJC_CLASS_$_AMapServices',
    '_OBJC_CLASS_$_AMapSearchAPI', '_TNVStart',
)
MAX_RESOURCE_BYTES = 256 * 1024 * 1024
MAX_RESOURCE_FILES = 20000


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def safe_relative(value):
    require(isinstance(value, str) and value and '\\' not in value, 'amap_unsafe_path')
    path = PurePosixPath(value)
    require(not path.is_absolute() and path.as_posix() == value, 'amap_unsafe_path')
    reserved = {'CON', 'PRN', 'AUX', 'NUL'} | {f'{p}{n}' for p in ('COM', 'LPT') for n in range(1, 10)}
    for part in path.parts:
        require(part not in ('.', '..') and not part.endswith((' ', '.'))
                and not any(ord(c) < 32 or c in '<>:"|?*' for c in part)
                and part.split('.')[0].upper() not in reserved, 'amap_unsafe_path')
    return path


def no_links(path):
    """Reject symlinks and Windows junctions in every existing path component."""
    path = Path(os.path.abspath(path))
    for item in [*reversed(path.parents), path]:
        info = item.lstat()
        require(not stat.S_ISLNK(info.st_mode)
                and not getattr(info, 'st_file_attributes', 0) & 0x400,
                'amap_symlink_or_reparse_point')
    return path


def inventory(root):
    root = no_links(root)
    require(root.is_dir(), 'amap_resources_missing')
    result, cases, total = {}, set(), 0

    def visit(folder):
        nonlocal total
        for child in sorted(folder.iterdir()):
            relative = child.relative_to(root).as_posix()
            safe_relative(relative)
            folded = relative.casefold()
            require(folded not in cases, 'amap_case_colliding_paths')
            cases.add(folded)
            info = child.lstat()
            require(not stat.S_ISLNK(info.st_mode)
                    and not getattr(info, 'st_file_attributes', 0) & 0x400,
                    'amap_symlink_or_reparse_point')
            if stat.S_ISDIR(info.st_mode):
                visit(child)
            else:
                require(stat.S_ISREG(info.st_mode), 'amap_non_regular_resource')
                total += info.st_size
                require(total <= MAX_RESOURCE_BYTES and len(result) < MAX_RESOURCE_FILES,
                        'amap_resource_limit')
                result[relative] = {'bytes': info.st_size, 'sha256': digest(child)}
    visit(root)
    require(result, 'amap_empty_resource_bundle')
    return result


def tree_digest(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def sdk_evidence(sdk_root):
    root = no_links(sdk_root)
    evidence = json.loads((root / 'sdk-evidence.json').read_text(encoding='utf-8'))
    require(evidence.get('versions') == VERSIONS and evidence.get('archives') == ARCHIVES,
            'amap_sdk_pins_mismatch')
    frameworks = {}
    for relative, (binary, header, macro, version) in FRAMEWORKS.items():
        directory = no_links(root / relative)
        text = no_links(directory / 'Headers' / header).read_text(encoding='utf-8', errors='replace')
        match = re.search(r'^\s*#\s*define\s+' + re.escape(macro) + r'\s+(\d+)\b', text, re.M)
        require(match and int(match[1]) == version, 'amap_header_version_mismatch_' + binary)
        target = no_links(directory / binary)
        frameworks[relative] = {'bytes': target.stat().st_size, 'sha256': digest(target),
                                'versionMacro': macro, 'versionNumber': version}
        require(frameworks[relative]['sha256'] == FRAMEWORK_SHA256[relative],
                'amap_framework_pin_mismatch_' + binary)
    require(frameworks == evidence.get('frameworks'), 'amap_framework_changed_after_setup')
    resources = {}
    for name, relative in RESOURCES.items():
        files = inventory(root / relative)
        resources[name] = {'files': files, 'treeSHA256': tree_digest(files)}
    require(resources == evidence.get('resources'), 'amap_resources_changed_after_setup')
    validate_resource_evidence(evidence)
    return evidence


def validate_resource_evidence(evidence):
    require(isinstance(evidence, dict) and evidence.get('versions') == VERSIONS
            and evidence.get('archives') == ARCHIVES, 'amap_sdk_pins_mismatch')
    resources = evidence.get('resources')
    require(isinstance(resources, dict) and set(resources) == set(RESOURCES), 'amap_resource_set_mismatch')
    total = 0
    for name, item in resources.items():
        files = item.get('files')
        require(isinstance(files, dict) and 0 < len(files) <= MAX_RESOURCE_FILES, 'amap_bad_resource_manifest')
        cases = set()
        for relative, record in files.items():
            safe_relative(relative)
            require(relative.casefold() not in cases, 'amap_case_colliding_paths')
            cases.add(relative.casefold())
            require(isinstance(record, dict) and set(record) == {'bytes', 'sha256'}
                    and type(record['bytes']) is int and record['bytes'] >= 0
                    and isinstance(record['sha256'], str)
                    and re.fullmatch('[0-9a-f]{64}', record['sha256']) is not None,
                    'amap_bad_resource_manifest')
            total += record['bytes']
        require(item.get('treeSHA256') == tree_digest(files), 'amap_manifest_tree_hash_mismatch')
        require(item['treeSHA256'] == RESOURCE_TREE_SHA256[name], 'amap_official_resource_pin_mismatch_' + name)
    require(total <= MAX_RESOURCE_BYTES, 'amap_resource_limit')
    return resources


def verify_resources(root, evidence):
    root = no_links(root)
    resources = validate_resource_evidence(evidence)
    require({p.name for p in root.iterdir()} == set(RESOURCES), 'amap_unexpected_resource_bundle')
    for name, item in resources.items():
        require(inventory(root / name) == item['files'], 'amap_resource_hash_mismatch_' + name)
    return resources


def copy_resources(source, destination, evidence, *, sdk_layout=False):
    """Preflight every source and collision before creating any destination bundle."""
    source, destination = no_links(source), no_links(destination)
    resources = validate_resource_evidence(evidence)
    if not sdk_layout:
        verify_resources(source, evidence)
    existing = {p.name.casefold() for p in destination.iterdir()}
    for name, item in resources.items():
        require(name.casefold() not in existing, 'amap_resource_collision_' + name)
        origin = source / (RESOURCES[name] if sdk_layout else name)
        require(inventory(origin) == item['files'], 'amap_resource_hash_mismatch_' + name)
    for name, item in resources.items():
        origin = source / (RESOURCES[name] if sdk_layout else name)
        target = destination / name
        target.mkdir(exist_ok=False)
        for relative, record in sorted(item['files'].items()):
            src, dst = no_links(origin / relative), target / relative
            dst.parent.mkdir(parents=True, exist_ok=True)
            no_links(dst.parent)
            content = src.read_bytes()
            require(len(content) == record['bytes'] and hashlib.sha256(content).hexdigest() == record['sha256'],
                    'amap_resource_changed_during_copy')
            with dst.open('xb') as output:
                output.write(content)
        require(inventory(target) == item['files'], 'amap_copied_resource_mismatch')
    return {name: item['treeSHA256'] for name, item in resources.items()}
