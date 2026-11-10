#!/usr/bin/env python3
"""Group-parallel parity: layout identity, cross-backend repair, telemetry and faults."""
import json
import os
from pathlib import Path
import random
import resource
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())


def run(*args, code=0, **kwargs):
    p = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, timeout=180, **kwargs)
    if p.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p


def geometry(archive):
    manifest = (archive / 'manifest.rzm').read_bytes()
    return struct.unpack_from('<QQ', manifest, 44)  # Stream size and data stripe count.


def payload(archive, parity=False):
    _, stripes = geometry(archive)
    volumes = [p.read_bytes() for p in sorted(archive.glob('p*.rzr' if parity else 'd*.rzv'))]
    result = bytearray()
    for block in range(stripes * len(volumes)):
        volume = volumes[block % len(volumes)]
        index_size = struct.unpack_from('<Q', volume, 40)[0]
        offset = 120 + index_size + block // len(volumes) * 65568
        result.extend(volume[offset:offset + 65536])
    return result


class ParallelRecoveryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='rz-parity-'))
        cls.source = cls.root / 'source'; cls.source.mkdir()
        cls.data = random.Random(3929).randbytes(13 * 1024 * 1024 + 173)
        (cls.source / 'data').write_bytes(cls.data)

    @classmethod
    def tearDownClass(cls): shutil.rmtree(cls.root)
    def setUp(self): self.work = Path(tempfile.mkdtemp(dir=self.root))
    def tearDown(self): shutil.rmtree(self.work)

    def test_parity_identity_and_full_budget_repair(self):
        for k, m in ((10, 1), (10, 2), (4, 4)):
            with self.subTest(k=k, m=m):
                archives = []
                for threads in (1, 4):
                    archive = self.work / f'k{k}-m{m}-t{threads}'
                    result = run('create', self.source, archive, '--threads', threads, '--no-metadata',
                                 '--data-volumes', k, '--recovery-volumes', m, '--progress')
                    records = [json.loads(line.split('\t', 1)[1]) for line in result.stderr.splitlines()
                               if line.startswith('RZTIMING1\t')]
                    self.assertEqual(len(records), 1); stats = records[0]
                    self.assertEqual(stats['version'], 1)
                    self.assertTrue(all(isinstance(v, int) and v >= 0 for v in stats.values()))
                    self.assertGreater(stats['rs_work_us'], 0)
                    self.assertGreater(stats['hash_work_us'], 0)
                    self.assertGreaterEqual(stats['packing_us'], stats['compression_us'])
                    stages = ('packing_us', 'recovery_wall_us', 'index_us', 'volume_write_us', 'verify_us', 'publish_us')
                    self.assertGreaterEqual(stats['total_us'], sum(stats[key] for key in stages))
                    self.assertLessEqual(stats['recovery_workers'], min(threads, geometry(archive)[1]))
                    self.assertLessEqual(stats['recovery_peak_jobs'], 2 * stats['recovery_workers'])
                    self.assertLessEqual(stats['recovery_estimated_bytes'], 256 * 1024 * 1024)
                    archives.append(archive)
                self.assertEqual(payload(archives[0]), payload(archives[1]))
                self.assertEqual(payload(archives[0], True), payload(archives[1], True))
                damaged = archives[1]
                volumes = sorted(damaged.glob('d*.rzv'))
                for volume in volumes[:m]:
                    volume.unlink()
                run('verify', damaged, code=2)
                repaired = self.work / f'repaired-{k}-{m}'; run('repair', damaged, repaired)
                output = self.work / f'out-{k}-{m}'; run('extract', repaired, output)
                self.assertEqual((output / 'data').read_bytes(), self.data)

    def test_neon_scalar_interoperation(self):
        scalar = {**os.environ, 'GF_COMPLETE_DISABLE_NEON': '1'}
        for index, (write_env, repair_env) in enumerate(((scalar, os.environ), (os.environ, scalar))):
            archive = self.work / f'cross-{index}'
            run('create', self.source, archive, '--threads', 4, '--no-metadata', env=write_env)
            volume = sorted(archive.glob('d*.rzv'))[0]
            with volume.open('r+b') as file:
                file.seek(40); size = struct.unpack('<Q', file.read(8))[0]
                file.seek(120 + size); value = file.read(1); file.seek(-1, 1); file.write(bytes([value[0] ^ 1]))
            repaired = self.work / f'cross-fixed-{index}'
            run('repair', archive, repaired, env=repair_env)
            output = self.work / f'cross-out-{index}'; run('extract', repaired, output, '--no-attributes', env=repair_env)
            self.assertEqual((output / 'data').read_bytes(), self.data)

    def test_payload_write_failure_cleans_staging(self):
        reference = self.work / 'reference'
        run('create', self.source, reference, '--data-volumes', 1, '--recovery-volumes', 1, '--threads', 1)
        stream_size = geometry(reference)[0]
        self.assertNotEqual(stream_size % 65536, 0)
        def limit():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (stream_size, stream_size))
        output = self.work / 'failed'
        # The compressed spool fits; padding its last data block exceeds the limit.
        result = run('create', self.source, output, '--data-volumes', 1, '--recovery-volumes', 1, '--threads', 4, '--progress', code=1, preexec_fn=limit)
        self.assertIn('RZPROGRESS1\trecovery\t', result.stderr)
        self.assertNotIn('RZPROGRESS1\twriting\t', result.stderr)
        self.assertIn('Write failed', result.stderr)
        self.assertFalse(output.exists()); self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_cancel_after_recovery_workers_commit(self):
        source = self.work / 'large'; source.mkdir()
        with (source / 'data').open('wb') as file:
            for _ in range(32): file.write(self.data[:4 * 1024 * 1024])
        for sig in (signal.SIGINT, signal.SIGTERM):
            output = self.work / f'cancel-{sig}'
            process = subprocess.Popen([BIN, 'create', str(source), str(output), '--threads', '4', '--no-metadata',
                                        '--data-volumes', '4', '--recovery-volumes', '4'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env={**os.environ, 'GF_COMPLETE_DISABLE_NEON': '1'}, text=True)
            try:
                active = False; deadline = time.monotonic() + 90
                while time.monotonic() < deadline and process.poll() is None:
                    for stage in self.work.glob('.rz-stage-*'):
                        try:
                            # Payload now goes straight into final-name staged
                            # volumes after the reserved bootstrap.
                            if any(path.stat().st_size > 8192 + 120 for path in stage.glob('*.rzv')): active = True
                        except FileNotFoundError: pass
                    if active: break
                    time.sleep(0.005)
                self.assertTrue(active, 'must cancel after a recovery group has been written')
                process.send_signal(sig); _, error = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 1); self.assertIn('cancelled', error)
                self.assertFalse(output.exists()); self.assertFalse(list(self.work.glob('.rz-stage-*')))
            finally:
                if process.poll() is None: process.kill()
                process.communicate()


if __name__ == '__main__': unittest.main()
