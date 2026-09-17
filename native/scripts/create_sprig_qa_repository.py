#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

"""Create an isolated real Git fixture; never points at an existing project."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1] / "build/SprigQARepository"
if root.exists():
    raise SystemExit(f"Fixture already exists, keeping it untouched: {root}")
root.mkdir(parents=True)

def git(*args):
    return subprocess.run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", *args], cwd=root, check=True, capture_output=True)

def write(path, content):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)

git("init", "-b", "fix/dispatch")
git("config", "user.name", "Sprig QA")
git("config", "user.email", "qa@example.invalid")
git("config", "commit.gpgsign", "false")
service = """package demo;

public class DispatchService {
    private final DemandRepository repository;

    public DispatchService(DemandRepository repository) {
        this.repository = repository;
    }

    public List<Demand> saveDemands(DispatchRequest request) {
        List<Demand> items = request.getDemands();
        return items.stream()
            .map(repository::save)
            .toList();
    }
}
"""
write("src/DispatchService.java", service)
write("config/application.yml", "server:\n  port: 8080\nspring:\n  datasource:\n    hikari:\n      maximum-pool-size: 10\n")
write("README.md", "# Sprig QA\n\nA real, isolated repository for native UI checks.\n")
write("old-name.txt", "This file will be renamed.\n")
write("obsolete.txt", "This file will be deleted.\n")
git("add", "."); git("commit", "-m", "chore: create native QA fixture")
service = service.replace("        return items.stream()", "        if (items == null || items.isEmpty()) {\n            return Collections.emptyList();\n        }\n        return items.stream()")
write("src/DispatchService.java", service)
write("config/application.yml", "server:\n  port: 8080\nspring:\n  datasource:\n    hikari:\n      maximum-pool-size: 30\n")
git("add", "src/DispatchService.java", "config/application.yml")
write("src/DispatchService.java", service.replace("        return items.stream()", "        // Keep this change out of the staged snapshot.\n        return items.stream()"))
write("README.md", "# Sprig QA\n\nVerify staged and working changes independently.\n")
git("mv", "old-name.txt", "renamed 文件.txt")
(root / "obsolete.txt").unlink()
write("notes/new file.txt", "An untracked file with a space in its path.\n")
(root / "image.bin").write_bytes(bytes([0, 1, 2, 3, 255]))
remote = root.parent / "SprigQARemote.git"
subprocess.run(["/usr/bin/git", "init", "--bare", str(remote)], check=True, capture_output=True)
git("remote", "add", "origin", str(remote))
git("push", "-u", "origin", "fix/dispatch")
git("branch", "main")
git("tag", "v0.1-fixture")
git("config", "core.hooksPath", "/dev/null")
print(root)
