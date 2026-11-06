"""Offline boundary tests for bounded, pinned AMap SDK downloads."""
import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import setup_amap_11_3_100 as setup


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.body = b'fixed public SDK archive fixture'
        self.name = 'pinned-sdk.zip'
        self.url = 'https://a.amap.com/lbs/static/zip/pinned-sdk.zip'
        self.pin = {'url': self.url, 'bytes': len(self.body),
                    'sha256': hashlib.sha256(self.body).hexdigest()}
        self.pins = patch.dict(setup.ARCHIVES, {self.name: self.pin}, clear=True)
        self.pins.start()
        self.cache = self.root / self.name
        self.unrelated = self.root / 'keep.part'
        self.unrelated.write_bytes(b'not owned by this download')

    def tearDown(self):
        self.pins.stop()
        self.temporary.cleanup()

    def fake_download(self, command, **options):
        Path(command[command.index('--output') + 1]).write_bytes(self.body)
        return subprocess.CompletedProcess(command, 0, stdout=self.url, stderr='')

    def assert_no_partial_cache(self):
        self.assertFalse(self.cache.exists())
        self.assertEqual(self.unrelated.read_bytes(), b'not owned by this download')
        self.assertEqual({p.name for p in self.root.iterdir()}, {'keep.part'})

    def test_success_has_bounded_ipv4_https_options_and_publishes_exact_bytes(self):
        with patch.object(setup.subprocess, 'run', side_effect=self.fake_download) as run:
            setup.obtain(self.root)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ['curl', '-q', '-4'])
        for option, expected in {'--proto': '=https', '--proto-redir': '=https',
                                 '--max-redirs': '3', '--connect-timeout': '15',
                                 '--max-time': '240', '--retry': '2',
                                 '--retry-delay': '2', '--retry-max-time': '300',
                                 '--max-filesize': str(len(self.body))}.items():
            self.assertEqual(command[command.index(option) + 1], expected)
        self.assertEqual(command[-1], self.url)
        self.assertEqual(run.call_args.kwargs,
                         {'check': True, 'capture_output': True, 'text': True, 'timeout': 360})
        self.assertNotIn('--insecure', command)
        self.assertEqual(self.cache.read_bytes(), self.body)
        self.assertEqual({p.name for p in self.root.iterdir()}, {self.name, 'keep.part'})

    def test_partial_download_failure_and_timeout_never_cache(self):
        for error in (subprocess.CalledProcessError(28, ['curl']),
                      subprocess.TimeoutExpired(['curl'], 360)):
            def fail(command, **options):
                Path(command[command.index('--output') + 1]).write_bytes(self.body[:5])
                raise error
            with self.subTest(error=type(error).__name__):
                with patch.object(setup.subprocess, 'run', side_effect=fail):
                    with self.assertRaises(type(error)):
                        setup.obtain(self.root)
                self.assert_no_partial_cache()

    def test_untrusted_final_url_length_and_digest_are_rejected(self):
        cases = [('https://example.invalid/sdk.zip', self.body, 'unexpected_download_redirect'),
                 ('https://a.amap.com.example.invalid/sdk.zip', self.body, 'unexpected_download_redirect'),
                 ('http://a.amap.com/sdk.zip', self.body, 'unexpected_download_redirect'),
                 ('https://user@a.amap.com/sdk.zip', self.body, 'unexpected_download_redirect'),
                 (self.url, self.body[:-1], 'pinned_archive_mismatch'),
                 (self.url, b'x' * len(self.body), 'pinned_archive_mismatch')]
        for final, content, reason in cases:
            def wrong(command, **options):
                Path(command[command.index('--output') + 1]).write_bytes(content)
                return subprocess.CompletedProcess(command, 0, stdout=final, stderr='')
            with self.subTest(url=final, reason=reason):
                with patch.object(setup.subprocess, 'run', side_effect=wrong):
                    with self.assertRaisesRegex(ValueError, reason):
                        setup.obtain(self.root)
                self.assert_no_partial_cache()

    def test_verified_cache_uses_no_network(self):
        self.cache.write_bytes(self.body)
        with patch.object(setup.subprocess, 'run') as run:
            setup.obtain(self.root)
        run.assert_not_called()
        self.assertEqual(self.cache.read_bytes(), self.body)

    def test_invalid_existing_cache_is_preserved_and_not_downloaded_over(self):
        self.cache.write_bytes(b'pre-existing invalid cache')
        with patch.object(setup.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'pinned_archive_mismatch'):
                setup.obtain(self.root)
        run.assert_not_called()
        self.assertEqual(self.cache.read_bytes(), b'pre-existing invalid cache')

    def test_concurrent_cache_publication_is_not_overwritten(self):
        def raced(command, **options):
            result = self.fake_download(command, **options)
            self.cache.write_bytes(b'another writer owns this path')
            return result
        with patch.object(setup.subprocess, 'run', side_effect=raced):
            with self.assertRaises(FileExistsError):
                setup.obtain(self.root)
        self.assertEqual(self.cache.read_bytes(), b'another writer owns this path')
        self.assertEqual({p.name for p in self.root.iterdir()}, {self.name, 'keep.part'})


if __name__ == '__main__':
    unittest.main()
