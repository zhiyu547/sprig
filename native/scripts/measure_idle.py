#!/usr/bin/env python3
# Copyright (c) 2026 zhiyu
# SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

"""Sample GitTool and its descendants via ps; report RSS, not physical footprint."""
import json
import pathlib
import platform
import statistics
import subprocess
import time

pids = subprocess.check_output(['/usr/bin/pgrep', '-x', 'GitTool'], text=True).split()
if len(pids) != 1:
    raise SystemExit('Open exactly one packaged GitTool app before measuring.')
root_pid = int(pids[0])
samples = []
for sample in range(30):
    rows = {}
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,rss=,%cpu='], text=True).splitlines():
        pid, parent, rss, cpu = line.split()
        rows[int(pid)] = (int(parent), int(rss), float(cpu))
    if root_pid not in rows:
        raise SystemExit('GitTool exited during measurement.')
    family = {root_pid}
    while True:
        expanded = family | {pid for pid, row in rows.items() if row[0] in family}
        if expanded == family:
            break
        family = expanded
    samples.append({'rssMB': round(sum(rows[pid][1] for pid in family)*1024/1_000_000, 2), 'cpuPercent': round(sum(rows[pid][2] for pid in family), 2), 'processCount': len(family)})
    if sample < 29:
        time.sleep(1)
report = {'timestamp': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'macOS': platform.mac_ver()[0], 'architecture': platform.machine(), 'samples': len(samples), 'metric': 'ps RSS in decimal MB; app + descendant processes', 'rssMB': {'median': statistics.median(s['rssMB'] for s in samples), 'min': min(s['rssMB'] for s in samples), 'max': max(s['rssMB'] for s in samples)}, 'cpuPercent': {'median': statistics.median(s['cpuPercent'] for s in samples), 'max': max(s['cpuPercent'] for s in samples)}, 'maxProcesses': max(s['processCount'] for s in samples), 'rawSamples': samples}
project = pathlib.Path(__file__).resolve().parents[1]
(project / 'build/idle-metrics.json').write_text(json.dumps(report, indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='rawSamples'}, indent=2))
