"""Boundary tests for downloaded resources crossing into a Windows IPA build."""
import copy
import io
import os
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from pathlib import Path
from amap_support import (ARCHIVES, RESOURCES, RESOURCE_TREE_SHA256, VERSIONS, copy_resources, inventory,
                          tree_digest, validate_resource_evidence, verify_resources)
from setup_amap_11_3_100 import extract_framework


class ResourceBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        # macOS exposes its trusted temporary directory through the /var alias.
        # Resolve only this freshly created fixture root; production paths retain
        # the no-symlink check, including links created inside these tests.
        self.root = Path(self.temp.name).resolve(strict=True)
        self.source, self.app = self.root / 'resources', self.root / 'Runner.app'
        self.source.mkdir()
        self.app.mkdir()
        self.evidence = {'versions': VERSIONS, 'archives': ARCHIVES, 'resources': {}}
        for name in RESOURCES:
            folder = self.source / name
            (folder / 'nested').mkdir(parents=True)
            (folder / 'nested' / '示例.data').write_bytes((name + '\0payload').encode())
            files = inventory(folder)
            self.evidence['resources'][name] = {'files': files, 'treeSHA256': tree_digest(files)}
        # Test fixtures have their own trusted pins; production pins remain fixed.
        self.pins = patch.dict(RESOURCE_TREE_SHA256,
                               {n: v['treeSHA256'] for n, v in self.evidence['resources'].items()}, clear=True)
        self.pins.start()

    def tearDown(self):
        self.pins.stop()
        self.temp.cleanup()

    def test_all_bundles_arrive_exactly_and_source_is_preserved(self):
        before = {name: inventory(self.source / name) for name in RESOURCES}
        (self.app / 'Info.plist').write_bytes(b'unchanged host metadata')
        copy_resources(self.source, self.app, self.evidence)
        for name in RESOURCES:
            self.assertEqual(inventory(self.app / name), before[name])
            self.assertEqual(inventory(self.source / name), before[name])
        self.assertEqual((self.app / 'Info.plist').read_bytes(), b'unchanged host metadata')

    def test_late_bundle_collision_does_not_copy_any_earlier_bundle(self):
        collision = self.app / 'AMapSearch.bundle'
        collision.mkdir()
        (collision / 'existing').write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'collision'):
            copy_resources(self.source, self.app, self.evidence)
        self.assertEqual({p.name for p in self.app.iterdir()}, {'AMapSearch.bundle'})
        self.assertEqual((collision / 'existing').read_text(), 'preserve')

    def test_changed_and_extra_source_files_are_rejected_before_copy(self):
        target = self.source / 'AMapSearch.bundle/nested/示例.data'
        target.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'hash_mismatch'):
            copy_resources(self.source, self.app, self.evidence)
        self.assertEqual(list(self.app.iterdir()), [])
        (self.source / 'secret.txt').write_text('unexpected artifact content')
        with self.assertRaisesRegex(ValueError, 'unexpected_resource_bundle'):
            verify_resources(self.source, self.evidence)

    def test_manifest_paths_cannot_escape_or_alias_on_windows(self):
        for unsafe in ('../outside', '/absolute', 'C:/outside', 'dir\\outside',
                       'file:stream', 'NUL.txt', 'folder/COM1', 'trailing.', 'trailing '):
            with self.subTest(path=unsafe):
                evidence = copy.deepcopy(self.evidence)
                item = evidence['resources']['AMap.bundle']
                record = next(iter(item['files'].values()))
                item['files'] = {unsafe: record}
                item['treeSHA256'] = tree_digest(item['files'])
                with self.assertRaises(ValueError):
                    copy_resources(self.source, self.app, evidence)
                self.assertEqual(list(self.app.iterdir()), [])

    def test_case_colliding_manifest_is_rejected_on_every_platform(self):
        evidence = copy.deepcopy(self.evidence)
        item = evidence['resources']['AMap.bundle']
        record = next(iter(item['files'].values()))
        item['files'] = {'icon.png': record, 'ICON.png': record}
        item['treeSHA256'] = tree_digest(item['files'])
        with self.assertRaisesRegex(ValueError, 'case_colliding'):
            validate_resource_evidence(evidence)

    def test_tampered_file_and_rewritten_manifest_still_fail_trusted_pin(self):
        target = self.source / 'AMapSearch.bundle/nested/示例.data'
        target.write_bytes(b'changed bytes with forged self-consistent metadata')
        forged = copy.deepcopy(self.evidence)
        files = inventory(self.source / 'AMapSearch.bundle')
        forged['resources']['AMapSearch.bundle'] = {'files': files, 'treeSHA256': tree_digest(files)}
        with self.assertRaisesRegex(ValueError, 'official_resource_pin_mismatch'):
            copy_resources(self.source, self.app, forged)
        self.assertEqual(list(self.app.iterdir()), [])

    def test_symlink_to_other_content_is_rejected_without_reading_target(self):
        outside = self.root / 'outside'
        outside.write_text('must not enter IPA')
        link = self.source / 'AMap.bundle' / 'link'
        try:
            os.symlink(outside, link)
        except (OSError, NotImplementedError):
            self.skipTest('OS does not allow this process to create symlinks')
        with self.assertRaisesRegex(ValueError, 'symlink_or_reparse'):
            copy_resources(self.source, self.app, self.evidence)
        self.assertEqual(list(self.app.iterdir()), [])

    def test_parent_symlink_is_also_rejected(self):
        alias = self.root / 'alias'
        try:
            os.symlink(self.source, alias, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest('OS does not allow this process to create symlinks')
        with self.assertRaisesRegex(ValueError, 'symlink_or_reparse'):
            verify_resources(alias, self.evidence)

    def test_zip_path_escape_and_symlink_never_create_destination(self):
        for filename, mode in (('../escaped', stat.S_IFREG),
                               ('Example.framework/link', stat.S_IFLNK)):
            memory = io.BytesIO()
            with zipfile.ZipFile(memory, 'w') as archive:
                entry = zipfile.ZipInfo(filename)
                entry.create_system = 3
                entry.external_attr = (mode | 0o644) << 16
                archive.writestr(entry, b'outside')
            memory.seek(0)
            destination = self.root / 'extracted'
            with zipfile.ZipFile(memory) as archive, self.assertRaises(ValueError):
                extract_framework(archive, 'Example.framework', destination)
            self.assertFalse(destination.exists())
            self.assertFalse((self.root / 'escaped').exists())


if __name__ == '__main__':
    unittest.main()
