#!/usr/bin/env python3
"""Local warm-cache benchmark; compares phase timings without changing source files."""
import argparse
import json
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import tempfile
import time


def measure(binary, source, output, threads, percent):
    start = time.monotonic(); phases = {}; timing = None
    with subprocess.Popen([str(binary), 'create', str(source), str(output), '--threads', str(threads),
                           '--no-metadata', '--progress', '--recovery-percent', str(percent)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True) as process:
        errors = []
        for line in process.stderr:
            if line.startswith('RZPROGRESS1\t'):
                phase = line.split('\t')[1]; phases.setdefault(phase, time.monotonic())
            elif line.startswith('RZTIMING1\t'): timing = json.loads(line.split('\t', 1)[1])
            else: errors.append(line)
        if process.wait(): raise RuntimeError(''.join(errors))
    result = {'total_ms': (time.monotonic() - start) * 1000,
              'recovery_phase_ms': (phases['writing'] - phases['recovery']) * 1000}
    if timing:
        for key in ('compression_us', 'recovery_wall_us', 'read_work_us', 'rs_work_us', 'hash_work_us',
                    'payload_write_us', 'volume_write_us', 'verify_us'):
            result[key.replace('_us', '_ms')] = timing[key] / 1000
        result['recovery_workers'] = timing['recovery_workers']
        result['recovery_estimated_mib'] = timing['recovery_estimated_bytes'] / 1024 / 1024
    shutil.rmtree(output)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--reference', type=Path, help='optional previous-version binary (4 compression workers)')
    parser.add_argument('--size-mib', type=int, default=128)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--output', type=Path, help='save JSON results')
    args = parser.parse_args()
    if args.size_mib < 4 or args.size_mib % 4 or args.repeats < 1:
        parser.error('size must be a positive multiple of 4 MiB and repeats must be positive')
    binary = args.binary.resolve(); modes = [('new-1', binary, 1), ('new-4', binary, 4), ('new-auto', binary, 'auto')]
    if args.reference: modes.insert(0, ('reference-4', args.reference.resolve(), 4))
    results = []; rng = random.Random(3929)
    # Repeated 4 MiB chunks have no cross-frame matches in this format.
    logs = b''.join(f'user={rng.randrange(10000)} path=/api/items/{rng.randrange(1000000)} status=200 trace={rng.getrandbits(64):016x}\n'.encode()
                    for _ in range(80000))[:4 * 1024 * 1024]
    chunks = {'logs': logs, 'random': rng.randbytes(4 * 1024 * 1024)}
    with tempfile.TemporaryDirectory(prefix='rz-recovery-benchmark-') as temporary:
        root = Path(temporary)
        for dataset, chunk in chunks.items():
            source = root / dataset; source.mkdir()
            with (source / 'data').open('wb') as file:
                for _ in range(args.size_mib // 4): file.write(chunk)
            for percent in (1, 20, 100):
                samples = {label: [] for label, _, _ in modes}
                for _ in range(args.repeats):
                    for label, executable, threads in modes:
                        samples[label].append(measure(executable, source, root / 'output.rz', threads, percent))
                for label, _, _ in modes:
                    result = {'dataset': dataset, 'size_mib': args.size_mib, 'recovery_percent': percent, 'mode': label,
                              **{key: round(statistics.median(row[key] for row in samples[label]), 3) for key in samples[label][0]}}
                    results.append(result); print(json.dumps(result), flush=True)
    if args.output: args.output.write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__': main()
