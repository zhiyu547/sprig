#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

"""Copy the release app with isolated preferences for local mock UI checks."""
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
target = root / "build/UIQA/Sprig QA.app"
if target.exists():
    shutil.rmtree(target)
shutil.copytree(root / "build/Sprig.app", target, symlinks=True)
info_path = target / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info.update(CFBundleIdentifier="cn.gittool.native.uiqa", CFBundleName="Sprig QA", CFBundleDisplayName="Sprig QA")
# UI fixtures must never receive official app updates under a different identity.
info.pop("SUFeedURL", None)
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(target)], check=True)
print(target)
