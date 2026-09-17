# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

"""Local-only UI fixture for synchronized push; never touches a business repo."""
import os
from pathlib import Path
import subprocess

base = Path(__file__).resolve().parents[1] / "build" / "SyncPushQA"
if base.exists():
    print(f"Existing fixture preserved: {base}")
    raise SystemExit(0)
base.mkdir(parents=True)
remote, workspace, colleague = (base / name for name in ("Remote.git", "Workspace", "Colleague"))
env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0")

def git(*args, at=base):
    return subprocess.run(["/usr/bin/git", *map(str, args)], cwd=at, env=env, check=True, capture_output=True, text=True).stdout.strip()

def identity(directory):
    git("config", "user.name", "Sprig UI Test", at=directory)
    git("config", "user.email", "test@example.invalid", at=directory)
    git("config", "commit.gpgsign", "false", at=directory)
    git("config", "core.hooksPath", directory / ".git/hooks", at=directory)

git("init", "--bare", "-b", "main", remote)
git("clone", remote, workspace)
identity(workspace)
(workspace / "README.md").write_text("# Sprig sync test\n")
(workspace / "app.txt").write_text("base\n")
(workspace / "draft.txt").write_text("base draft\n")
git("add", ".", at=workspace); git("commit", "-m", "chore: initial fixture", at=workspace)
git("push", "-u", "origin", "main", at=workspace)
git("clone", remote, colleague); identity(colleague)
(workspace / "local-feature.txt").write_text("Local feature\n")
git("add", ".", at=workspace); git("commit", "-m", "feat: local feature", at=workspace)
(colleague / "remote-feature.txt").write_text("Colleague feature\n")
git("add", ".", at=colleague); git("commit", "-m", "feat: colleague feature", at=colleague); git("push", at=colleague)
(workspace / "draft.txt").write_text("selected draft\n")
git("add", "draft.txt", at=workspace)
(workspace / "draft.txt").write_text("selected draft\nremaining draft\n")
(workspace / "local-note.txt").write_text("untracked draft\n")
print(f"Open in Sprig QA: {workspace}")
print("Diverged main; partial staged draft and untracked note must survive push.")
