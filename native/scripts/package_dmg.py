#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
"""Create a drag-to-Applications DMG from the already-verified app."""
import pathlib
import shutil
import subprocess
import tempfile
from package_app import ROOT, release_config

config = release_config()
app = ROOT / "build/Sprig.app"
target = ROOT / "build/release" / config["version"] / f'Sprig-{config["version"]}-macos-universal.dmg'
target.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="sprig-dmg-") as temporary:
    stage = pathlib.Path(temporary)
    shutil.copytree(app, stage / "Sprig.app", symlinks=True)
    (stage / "Applications").symlink_to("/Applications")
    subprocess.run(["hdiutil", "create", "-volname", "Sprig", "-srcfolder", str(stage),
                    "-ov", "-format", "UDZO", str(target)], check=True)
subprocess.run(["hdiutil", "verify", str(target)], check=True)
print(target)
