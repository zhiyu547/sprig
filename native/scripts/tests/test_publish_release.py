# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
import hashlib
import io
import pathlib
import runpy
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import package_app
import prepare_release


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.config = package_app.release_config()
        self.build = int(self.config['build'])
        version = self.config['version']
        self.base = f'https://github.com/{self.config["repository"]}/releases'
        self.published = self.assets(b'published')
        local = self.root / 'build/release' / version
        local.mkdir(parents=True)
        for name, content in self.assets(b'current build').items():
            (local / name).write_bytes(content)
        self.verify = mock.Mock()
        self.github = mock.Mock()

    def feed(self, build):
        namespace = prepare_release.NS[1:-1]
        return (f'<rss xmlns:sparkle="{namespace}"><channel><item>'
                f'<sparkle:version>{build}</sparkle:version></item></channel></rss>').encode()

    def assets(self, binary):
        name = f'Sprig-{self.config["version"]}-macos-universal'
        files = {name + '.zip': binary, 'appcast.xml': self.feed(self.build), name + '.dmg': b'disk ' + binary}
        files['SHA256SUMS.txt'] = ''.join(
            f'{hashlib.sha256(content).hexdigest()}  {name}\n' for name, content in files.items()
        ).encode()
        return files

    def run_publish(self, latest, assets):
        tag = 'v' + self.config['version']
        downloads = {f'{self.base}/download/{tag}/{name}': content for name, content in assets.items()}
        downloads[f'{self.base}/latest/download/appcast.xml'] = latest

        def read(url, timeout):
            if url not in downloads:
                raise urllib.error.HTTPError(url, 404, 'Not found', {}, None)
            return io.BytesIO(downloads[url])

        with mock.patch.multiple(package_app, ROOT=self.root, release_config=lambda: self.config):
            with mock.patch.object(prepare_release, 'verify', self.verify), mock.patch('subprocess.run', self.github):
                with mock.patch('urllib.request.urlopen', side_effect=read):
                    runpy.run_path(str(SCRIPTS / 'publish_release.py'), run_name='__main__')

    def test_equal_build_verifies_public_assets_without_mutating_release(self):
        self.run_publish(self.published['appcast.xml'], self.published)
        self.assertEqual(self.verify.call_count, 2)
        self.github.assert_not_called()

    def test_equal_build_rejects_corrupt_published_attachment(self):
        archive = next(name for name in self.published if name.endswith('.zip'))
        self.published[archive] = b'corrupt replacement'
        with self.assertRaisesRegex(SystemExit, 'checksum'):
            self.run_publish(self.published['appcast.xml'], self.published)
        self.github.assert_not_called()

    def test_older_build_still_cannot_replace_stable_release(self):
        with self.assertRaisesRegex(SystemExit, 'must exceed'):
            self.run_publish(self.feed(self.build + 1), {})
        self.github.assert_not_called()

    def test_new_build_still_creates_uploads_and_publishes(self):
        self.run_publish(self.feed(self.build - 1), {})
        self.assertEqual([call.args[0][1:3] for call in self.github.call_args_list],
                         [['release', 'create'], ['release', 'upload'], ['release', 'edit']])
