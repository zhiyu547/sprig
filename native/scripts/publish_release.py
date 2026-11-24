#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
"""Publish an already verified release. Requires an authenticated GitHub CLI."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from package_app import ROOT, PROJECT, release_config
from prepare_release import NS, checksum_manifest, verify


def verify_published(config, url, stable_feed, asset_names):
    with tempfile.TemporaryDirectory(prefix='sprig-published-') as directory:
        archive, feed, image, checksums = (Path(directory) / name for name in asset_names)
        for asset in (archive, feed, image, checksums):
            with urllib.request.urlopen(f'{url}/{asset.name}', timeout=30) as response, asset.open('wb') as output:
                shutil.copyfileobj(response, output)
        if feed.read_bytes() != stable_feed:
            raise SystemExit('Latest update feed does not match this published release')
        if sorted(checksums.read_text().splitlines()) != sorted(checksum_manifest([archive, feed, image]).splitlines()):
            raise SystemExit('Published release checksum mismatch')
        verify(feed, archive, config)


def main():
    config = release_config()
    version = config['version']
    tag = 'v' + version
    repo = config['repository']
    folder = ROOT / 'build/release' / version
    name = f'Sprig-{version}-macos-universal'
    asset_names = [name + '.zip', 'appcast.xml', name + '.dmg', 'SHA256SUMS.txt']
    verify(folder / 'appcast.xml', folder / asset_names[0], config)

    releases = f'https://github.com/{repo}/releases'
    try:
        with urllib.request.urlopen(f'{releases}/latest/download/appcast.xml', timeout=30) as response:
            stable_feed = response.read()
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        previous = ET.fromstring(stable_feed)
        builds = (int(node.text) for node in previous.findall('./channel/item/' + NS + 'version'))
        published_build = max(builds, default=0)
        build = int(config['build'])
        if build < published_build:
            raise SystemExit('Release build number must exceed the currently published build')
        if build == published_build:
            verify_published(config, f'{releases}/download/{tag}', stable_feed, asset_names)
            print(f'{tag} is already published. Verified public assets and signatures.')
            return

    assets = [folder / name for name in asset_names]
    for asset in assets:
        if not asset.is_file():
            raise SystemExit(f'Missing release asset: {asset.name}')

    def gh(*args):
        subprocess.run(['gh', *args, '--repo', repo], check=True)

    gh('release', 'create', tag, '--verify-tag', '--draft', '--title', 'Sprig ' + version,
       '--notes-file', str(PROJECT / 'docs/releases' / (version + '.md')))
    gh('release', 'upload', tag, *(str(asset) for asset in assets))
    gh('release', 'edit', tag, '--draft=false', '--latest')


if __name__ == '__main__':
    main()
