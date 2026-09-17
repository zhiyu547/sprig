#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
"""Sign a release with Sparkle, then independently verify it using the public key."""
import argparse
import base64
import hashlib
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from package_app import ROOT, PROJECT, release_config

NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
KEY_ACCOUNT = "cn.gittool.native.sparkle"


def inspect_archive(archive, config):
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("Sprig.app/Contents/Info.plist"))
        for key, expected in {
            "CFBundleIdentifier": config["bundleIdentifier"],
            "CFBundleVersion": config["build"],
            "CFBundleShortVersionString": config["version"],
            "SUPublicEDKey": config["sparklePublicKey"],
            "SUFeedURL": f'https://github.com/{config["repository"]}/releases/latest/download/appcast.xml',
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        }.items():
            if info.get(key) != expected:
                raise ValueError(f"Archive {key} does not match release.json")
        if bundle.read("Sprig.app/Contents/Resources/Licenses/LICENSE.txt") != (PROJECT / "LICENSE").read_bytes():
            raise ValueError("Missing or outdated application license")


def inspect_feed(feed, archive, config):
    raw = feed.read_bytes()
    # Sparkle appends a signature comment; the exact preceding bytes are signed.
    match = re.search(rb"<!-- sparkle-signatures:\n(.*?)-->\s*$", raw, re.S)
    if not match:
        raise ValueError("The appcast is not signed")
    metadata = dict(line.split(b":", 1) for line in match[1].splitlines() if b":" in line)
    signature = metadata.get(b"edSignature", b"").strip().decode("ascii")
    if len(base64.b64decode(signature, validate=True)) != 64 or int(metadata.get(b"length", b"-1")) != match.start():
        raise ValueError("Malformed appcast signature or length")
    items = ET.fromstring(raw).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Each release feed must contain exactly this release")
    item = items[0]
    if item.findtext(NS + "version") != config["build"] or item.findtext(NS + "shortVersionString") != config["version"]:
        raise ValueError("Appcast version does not match release.json")
    enclosure = item.find("enclosure")
    expected_url = f'https://github.com/{config["repository"]}/releases/download/v{config["version"]}/{archive.name}'
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Appcast download URL does not match this release")
    if int(enclosure.get("length", "-1")) != archive.stat().st_size:
        raise ValueError("Appcast archive length is incorrect")
    archive_signature = enclosure.get(NS + "edSignature", "")
    if len(base64.b64decode(archive_signature, validate=True)) != 64:
        raise ValueError("Archive signature is missing")
    return raw[:match.start()], signature, archive_signature


def verify(feed, archive, config):
    inspect_archive(archive, config)
    content, signature, archive_signature = inspect_feed(feed, archive, config)
    verifier = ROOT / "scripts/verify_signature.swift"
    with tempfile.TemporaryDirectory(prefix="sprig-verify-") as folder:
        payload = pathlib.Path(folder) / "feed.xml"
        payload.write_bytes(content)
        for path, sig in [(payload, signature), (archive, archive_signature)]:
            subprocess.run(["swift", str(verifier), str(path), config["sparklePublicKey"], sig], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--directory", type=pathlib.Path)
    args = parser.parse_args()
    config = release_config()
    folder = args.directory or ROOT / "build/release" / config["version"]
    archives = list(folder.glob("Sprig-*-macos-universal.zip"))
    if len(archives) != 1:
        raise SystemExit("Exactly one universal archive is required")
    archive = archives[0]
    inspect_archive(archive, config)
    feed = folder / "appcast.xml"
    if not args.verify_only:
        source_notes = PROJECT / "docs/releases" / (config["version"] + ".md")
        notes = archive.with_suffix(".md")
        shutil.copy2(source_notes, notes)
        tool = ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
        command = [str(tool), "--maximum-deltas", "0", "--embed-release-notes", "--download-url-prefix",
                   f'https://github.com/{config["repository"]}/releases/download/v{config["version"]}/',
                   "--link", f'https://github.com/{config["repository"]}']
        private_key = os.environ.get("SPARKLE_PRIVATE_KEY")
        if private_key:
            command += ["--ed-key-file", "-"]
        else:
            command += ["--account", KEY_ACCOUNT]
        # Secrets travel only over stdin; never through args or a temporary file.
        process_env = dict(os.environ)
        process_env.pop("SPARKLE_PRIVATE_KEY", None)
        # DMG is for first installation, ZIP is the single updater artifact.
        # Feed generation must not see two archives with the same bundle version.
        with tempfile.TemporaryDirectory(prefix="sprig-appcast-") as temporary:
            staging = pathlib.Path(temporary)
            shutil.copy2(archive, staging / archive.name)
            shutil.copy2(notes, staging / notes.name)
            subprocess.run(command + [str(staging)], input=private_key, text=True, env=process_env, check=True)
            shutil.copy2(staging / "appcast.xml", feed)
    verify(feed, archive, config)
    if not args.verify_only:
        assets = [archive, feed]
        assets += sorted(folder.glob("*.dmg"))
        checksum = "".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in assets)
        (folder / "SHA256SUMS.txt").write_text(checksum)
    print(f"Verified release {config['version']} (build {config['build']})")


if __name__ == "__main__":
    main()
