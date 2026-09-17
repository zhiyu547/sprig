#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
"""Package a SwiftPM build, preserving Sparkle's signed bundle and symlinks."""
import argparse
import base64
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = ROOT.parent


def release_config(path=ROOT / "release.json"):
    config = json.loads(path.read_text())
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", config["version"]):
        raise ValueError("Release version must be major.minor.patch")
    if not re.fullmatch(r"[1-9][0-9]*", config["build"]):
        raise ValueError("Build number must be a positive integer")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config["repository"]):
        raise ValueError("Invalid GitHub owner/repository")
    if len(base64.b64decode(config["sparklePublicKey"], validate=True)) != 32:
        raise ValueError("A valid 32-byte Sparkle public key is required")
    return config


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64", "universal"], default="universal")
    parser.add_argument("--bin-dir", type=pathlib.Path)
    args = parser.parse_args()
    config = release_config()
    arch_flags = ["--arch", "arm64", "--arch", "x86_64"] if args.arch == "universal" else ["--arch", args.arch]
    bin_dir = args.bin_dir or pathlib.Path(run("swift", "build", "--package-path", ROOT, "-c", "release", *arch_flags,
                                             "--show-bin-path", capture_output=True, text=True).stdout.strip())
    executable = bin_dir / "GitTool"
    if not executable.is_file():
        raise SystemExit(f"Build GitTool for {args.arch} first; not found: {executable}")
    framework = ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if not framework.is_dir():
        raise SystemExit("Resolve the pinned Sparkle dependency before packaging")
    app = ROOT / "build/Sprig.app"
    # Only this generated app bundle is replaced; local test repositories are retained.
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for directory in ["MacOS", "Resources/Licenses", "Frameworks"]:
        (contents / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, contents / "MacOS/GitTool")
    shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
    iconset = ROOT / "build/Sprig.iconset"
    iconset.mkdir(exist_ok=True)
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            run("/usr/bin/sips", "-z", size * scale, size * scale, ROOT / "Resources/Sprig.png", "--out", iconset / name,
                capture_output=True)
    run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", contents / "Resources/Sprig.icns")
    for name in ["LICENSE", "LICENSE.zh-CN.md", "NOTICE", "THIRD_PARTY_NOTICES.md", "PRIVACY.md"]:
        target = name.removesuffix(".md") + ".txt"
        shutil.copy2(PROJECT / name, contents / "Resources/Licenses" / target)
    shutil.copy2(PROJECT / "licenses/Sparkle-LICENSE.txt", contents / "Resources/Licenses/Sparkle-LICENSE.txt")
    info = {
        "CFBundleExecutable": "GitTool", "CFBundleIdentifier": config["bundleIdentifier"],
        "CFBundleName": "Sprig", "CFBundleDisplayName": "Sprig", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": config["version"], "CFBundleVersion": config["build"],
        "CFBundleIconFile": "Sprig", "LSMinimumSystemVersion": config["minimumSystemVersion"],
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "NSHumanReadableCopyright": config["copyright"],
        "SUFeedURL": f'https://github.com/{config["repository"]}/releases/latest/download/appcast.xml',
        "SUPublicEDKey": config["sparklePublicKey"],
        "SUEnableAutomaticChecks": True, "SUScheduledCheckInterval": 86400,
        "SUAllowsAutomaticUpdates": False, "SUAutomaticallyUpdate": False,
        "SUEnableSystemProfiling": False, "SUSendProfileInfo": False,
        "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "Resources/Credits.html").write_text(
        '<html><body><p>Copyright © 2026 zhiyu</p>'
        '<p>Sprig Non-Commercial Share-Alike License 1.0. Internal business use permitted.</p>'
        '<p>Includes Sparkle. See the application’s License and Third-party notices controls.</p>'
        '<p><a href="https://github.com/' + config["repository"] + '">Project and corresponding source</a></p>'
        '</body></html>')
    # Preserve the upstream signatures of Sparkle and helpers; ad-hoc sign the host.
    # No hardened runtime / library validation is enabled for this ad-hoc build.
    run("/usr/bin/codesign", "--force", "--sign", "-", app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    architectures = set(run("/usr/bin/lipo", "-archs", contents / "MacOS/GitTool", capture_output=True, text=True).stdout.split())
    expected = {"arm64", "x86_64"} if args.arch == "universal" else {args.arch}
    if architectures != expected:
        raise SystemExit(f"Unexpected architectures: {architectures}, expected {expected}")
    output = ROOT / "build/release" / config["version"]
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'Sprig-{config["version"]}-macos-{args.arch}.zip'
    if archive.exists():
        archive.unlink()
    # ditto retains symlinks and executable permissions, unlike make_archive.
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    metrics = {"version": config["version"], "build": config["build"], "architecture": args.arch,
               "appBytes": sum(p.stat().st_size for p in app.rglob("*") if p.is_file() and not p.is_symlink()),
               "zipBytes": archive.stat().st_size}
    (ROOT / "build/package-metrics.json").write_text(json.dumps(metrics, indent=2))
    print(app); print(archive); print(json.dumps(metrics))


if __name__ == "__main__":
    main()
