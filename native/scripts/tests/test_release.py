# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
import base64
import copy
import json
import pathlib
import plistlib
import sys
import tempfile
import unittest
import zipfile
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from package_app import release_config, PROJECT
from prepare_release import inspect_archive, inspect_feed


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = pathlib.Path(self.temporary.name)
        self.config = release_config()

    def test_rejects_invalid_key_repository_and_version(self):
        for field, value in [("sparklePublicKey", "secret"), ("repository", "owner/repo/../../other"),
                             ("version", "v1.0.0; unsafe"), ("build", "0")]:
            config = dict(self.config, **{field: value})
            path = self.folder / "config.json"
            path.write_text(json.dumps(config))
            with self.assertRaises(ValueError):
                release_config(path)

    def test_archive_must_embed_release_identity_key_and_license(self):
        c = self.config
        info = {"CFBundleIdentifier": c["bundleIdentifier"], "CFBundleVersion": c["build"],
                "CFBundleShortVersionString": c["version"], "SUPublicEDKey": c["sparklePublicKey"],
                "SUFeedURL": f'https://github.com/{c["repository"]}/releases/latest/download/appcast.xml',
                "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True}
        for key in [None, "CFBundleIdentifier", "CFBundleVersion", "SUPublicEDKey", "SUFeedURL", "SURequireSignedFeed"]:
            candidate = copy.deepcopy(info)
            if key:
                candidate[key] = "incorrect"
            archive = self.folder / "app.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("Sprig.app/Contents/Info.plist", plistlib.dumps(candidate))
                output.writestr("Sprig.app/Contents/Resources/Licenses/LICENSE.txt", (PROJECT / "LICENSE").read_bytes())
            if key:
                with self.assertRaises(ValueError):
                    inspect_archive(archive, c)
            else:
                inspect_archive(archive, c)

    def test_feed_rejects_unsigned_metadata_wrong_versions_and_downloads(self):
        c = self.config
        archive = self.folder / f'Sprig-{c["version"]}-macos-universal.zip'
        archive.write_bytes(b"fixture")
        signature = base64.b64encode(bytes(64)).decode()
        url = f'https://github.com/{c["repository"]}/releases/download/v{c["version"]}/{archive.name}'
        xml = (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
               f'<sparkle:version>{c["build"]}</sparkle:version><sparkle:shortVersionString>{c["version"]}</sparkle:shortVersionString>'
               f'<enclosure url="{url}" length="7" sparkle:edSignature="{signature}"/></item></channel></rss>\n')
        feed = self.folder / "appcast.xml"
        feed.write_text(xml)
        with self.assertRaisesRegex(ValueError, "not signed"):
            inspect_feed(feed, archive, c)
        for content in [xml, xml.replace(url, "https://example.invalid/malicious.zip"),
                        xml.replace('length="7"', 'length="8"'), xml.replace(f'<sparkle:version>{c["build"]}', '<sparkle:version>0')]:
            feed.write_text(content + f'<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content.encode())}\n-->\n')
            if content == xml:
                self.assertEqual(inspect_feed(feed, archive, c)[0], xml.encode())
            else:
                with self.assertRaises(ValueError):
                    inspect_feed(feed, archive, c)


if __name__ == "__main__":
    unittest.main()
