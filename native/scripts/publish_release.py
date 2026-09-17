#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
"""Publish an already verified release. Requires an authenticated GitHub CLI."""
import json
import subprocess
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from package_app import ROOT, PROJECT, release_config
from prepare_release import NS, verify

c = release_config()
tag = 'v' + c['version']
folder = ROOT / 'build/release' / c['version']
archive = folder / f'Sprig-{c["version"]}-macos-universal.zip'
verify(folder / 'appcast.xml', archive, c)
# Do not accidentally move the stable update feed backwards.
try:
    with urllib.request.urlopen(f'https://github.com/{c["repository"]}/releases/latest/download/appcast.xml', timeout=30) as response:
        previous = ET.fromstring(response.read())
    builds = [int(node.text) for node in previous.findall('./channel/item/' + NS + 'version')]
    if builds and int(c['build']) <= max(builds):
        raise SystemExit('Release build number must exceed the currently published build')
except urllib.error.HTTPError as error:
    if error.code != 404:
        raise

def gh(*args):
    return subprocess.run(['gh', *args, '--repo', c['repository']], check=True)

assets = [archive, folder / f'Sprig-{c["version"]}-macos-universal.dmg', folder / 'appcast.xml', folder / 'SHA256SUMS.txt']
for asset in assets:
    if not asset.is_file():
        raise SystemExit(f'Missing release asset: {asset.name}')
gh('release', 'create', tag, '--verify-tag', '--draft', '--title', 'Sprig ' + c['version'],
   '--notes-file', str(PROJECT / 'docs/releases' / (c['version'] + '.md')))
gh('release', 'upload', tag, *(str(asset) for asset in assets))
gh('release', 'edit', tag, '--draft=false', '--latest')
