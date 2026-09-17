#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

"""Measure GitCore reads on an isolated 10,000-file repository (warm cache)."""
import json
import math
import pathlib
import statistics
import subprocess

project = pathlib.Path(__file__).resolve().parents[1]
root = project / 'build/BenchmarkRepository'
marker = project / 'build/benchmark-fixture.json'

def git(*args):
    return subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', *args], cwd=root, check=True, capture_output=True)

if not root.exists():
    root.mkdir(parents=True)
    git('init', '-b', 'benchmark/read-only')
    git('config', 'user.name', 'Git Tool Benchmark')
    git('config', 'user.email', 'benchmark@example.invalid')
    git('config', 'commit.gpgsign', 'false')
    for directory in range(100):
        folder = root / f'module-{directory:03}'
        folder.mkdir()
        for file in range(100):
            (folder / f'file-{file:03}.txt').write_text(''.join(f'line {line:03}: baseline content\n' for line in range(80)))
    git('add', '.'); git('commit', '-m', 'chore: benchmark baseline')
    for file in range(20):
        target = root / f'module-000/file-{file:03}.txt'
        target.write_text(target.read_text().replace('line 040: baseline content', 'line 040: changed content'))
    marker.write_text(json.dumps({'trackedFiles': 10000, 'changedFiles': 20}))
elif not marker.exists():
    raise SystemExit('Existing directory has no fixture marker; left untouched.')

probe = project / '.build/release/GitProbe'
args = [str(probe), str(root), 'module-000/file-000.txt', 'working']
subprocess.run(args, check=True, capture_output=True) # excluded warm-up
runs = [json.loads(subprocess.check_output(args)) for _ in range(20)]
status = [r['statusMilliseconds'] for r in runs]
diff = [r['diff']['milliseconds'] for r in runs]

def summary(values):
    return {'median': statistics.median(values), 'p95': sorted(values)[math.ceil(len(values)*0.95)-1], 'min': min(values), 'max': max(values)}

report = {'fixture': str(root), 'trackedFiles': 10000, 'changedFiles': len(runs[0]['files']), 'diffBytesTotal': len(git('diff', '--no-ext-diff', '--no-textconv').stdout), 'samples': 20, 'cache': 'warm', 'openAndStatusMilliseconds': summary(status), 'selectedFileDiffMilliseconds': summary(diff)}
(project / 'build/git-benchmark.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
