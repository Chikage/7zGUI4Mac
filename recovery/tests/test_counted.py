#!/usr/bin/env python3
"""Profile 4: equal volumes, whole-volume guarantees, index protection and scheduling."""
import itertools
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
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
BLOCK, HEADER = 65536, 120


def run(*args, code=0, **kwargs):
    result = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, timeout=180, **kwargs)
    if result.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def volumes(path):
    return sorted([*path.glob('*.rzv'), *path.glob('*.rzr')])


def info(path):
    return json.loads(run('list', path, '--json', '--no-auto-key-file').stdout)


def layout(path):
    raw = (path / 'manifest.rzm').read_bytes()[:-32]
    assert raw[:8] == b'RZIDX004'
    k, m, stripes = struct.unpack_from('<III', raw, 56)
    stream, data, parity, groups = struct.unpack_from('<QQQI', raw, 68)
    assert groups == stripes and data == k * stripes and parity == m * stripes
    return raw, k, m, stripes, stream


def flip(path, offset, size=1):
    with path.open('r+b') as file:
        file.seek(offset); value = file.read(size)
        assert len(value) == size
        file.seek(offset); file.write(bytes(b ^ 0xa5 for b in value))


def payload(path):
    result = []
    for volume in volumes(path):
        raw = volume.read_bytes()
        index, size = struct.unpack_from('<QQ', raw, 40)
        result.append(raw[HEADER + index:HEADER + index + size])
    return result


class CountedVolumesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='rz-counted-')
        cls.root = Path(cls.tmp.name)
        cls.source = cls.root / 'source'; cls.source.mkdir()
        cls.data = random.Random(4591).randbytes(1024 * 1024 + 317)
        (cls.source / 'data').write_bytes(cls.data)
        (cls.source / 'data').chmod(0o640)
        (cls.source / 'empty').mkdir()
        cls.archive = cls.root / 'original'
        run('create', cls.source, cls.archive, '--data-volumes', 4, '--recovery-volumes', 2)
        cls.original = {file.name: file.read_bytes() for file in cls.archive.iterdir()}

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def setUp(self): self.work = Path(tempfile.mkdtemp(dir=self.root))
    def tearDown(self): shutil.rmtree(self.work)

    def damaged(self):
        target = self.work / 'damaged'; shutil.copytree(self.archive, target); return target

    def check_repair(self, broken, *, env=None):
        fixed = self.work / 'fixed'
        run('verify', broken, code=2)
        run('repair', broken, fixed, env=env)
        self.assertEqual({file.name: file.read_bytes() for file in fixed.iterdir()}, self.original)
        output = self.work / 'output'; run('extract', fixed, output)
        self.assertEqual((output / 'data').read_bytes(), self.data)
        self.assertEqual((output / 'data').stat().st_mode & 0o777, 0o640)
        self.assertTrue((output / 'empty').is_dir())
        shutil.rmtree(fixed); shutil.rmtree(output)

    def test_all_two_volume_losses_are_byte_exact(self):
        for lost in itertools.combinations([p.name for p in volumes(self.archive)], 2):
            with self.subTest(lost=lost):
                broken = self.damaged()
                for name in lost: (broken / name).unlink()
                self.check_repair(broken)
                shutil.rmtree(broken)

    def test_sizes_padding_and_count_boundaries(self):
        small = self.work / 'small'; small.mkdir(); (small / 'one').write_bytes(b'x')
        for k, m in ((1, 1), (3, 1), (7, 3), (10, 2), (100, 100)):
            archive = self.work / f'{k}-{m}'
            run('create', small, archive, '--data-volumes', k, '--recovery-volumes', m)
            raw, actual_k, actual_m, stripes, stream = layout(archive)
            self.assertEqual((actual_k, actual_m), (k, m))
            self.assertEqual(stripes, max(1, (stream + k * BLOCK - 1) // (k * BLOCK)))
            self.assertEqual(len(volumes(archive)), k + m)
            sizes = {file.stat().st_size for file in volumes(archive)}
            self.assertEqual(sizes, {2 * HEADER + 2 * len(raw) + stripes * BLOCK})
            details = info(archive)['recovery']
            self.assertEqual(details['volumeSizeBytes'], sizes.pop())
            self.assertEqual(details['toleratedVolumeLosses'], m)
            for volume in sorted(archive.glob('*.rzv'))[:m]: volume.unlink()
            fixed = self.work / f'fixed-{k}'
            run('repair', archive, fixed)
            output = self.work / f'out-{k}'; run('extract', fixed, output)
            self.assertEqual((output / 'one').read_bytes(), b'x')
        empty = self.work / 'empty'; empty.mkdir()
        run('create', empty, self.work / 'empty-set', '--profile', 4)
        self.assertEqual(len(volumes(self.work / 'empty-set')), 12)

    def test_mixed_loss_and_local_corruption(self):
        broken = self.damaged(); raw, _, _, stripes, _ = layout(broken)
        (broken / 'd000000.rzv').unlink()
        remaining = volumes(broken)
        for stripe in range(stripes):
            flip(remaining[stripe % len(remaining)], HEADER + len(raw) + stripe * BLOCK)
        self.check_repair(broken, env={**os.environ, 'GF_COMPLETE_DISABLE_NEON': '1'})

    def test_over_budget_is_not_published(self):
        broken = self.damaged(); raw, *_ = layout(broken)
        for file in volumes(broken)[:3]: flip(file, HEADER + len(raw))
        run('verify', broken, code=3)
        output = self.work / 'failed'; run('repair', broken, output, code=1)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_private_index_and_metadata_are_repaired(self):
        broken = self.damaged(); raw, k, m, stripes, _ = layout(broken)
        private_offset = struct.unpack_from('<Q', raw, 96 + stripes * (8 + (k + m) * 32) + 16)[0]
        block = private_offset // BLOCK
        flip(broken / f'd{block % k:06}.rzv', HEADER + len(raw) + block // k * BLOCK)
        if block != 0: flip(broken / 'd000000.rzv', HEADER + len(raw))
        self.assertTrue(info(broken)['directoryUnavailable'])
        self.check_repair(broken)

    def test_public_index_fallback_and_total_loss(self):
        broken = self.damaged(); raw, *_ = layout(broken)
        (broken / 'manifest.rzm').unlink()
        for file in volumes(broken): flip(file, 0, HEADER + len(raw))
        self.check_repair(broken)
        for file in volumes(broken): flip(file, file.stat().st_size - HEADER - len(raw), HEADER + len(raw))
        self.assertIn('No valid manifest', run('repair', broken, self.work / 'failed', code=1).stderr)

    def test_serial_parallel_identity_and_worker_limits(self):
        archives = []
        for threads in (1, 4, 'auto'):
            archive = self.work / f't{threads}'
            result = run('create', self.source, archive, '--data-volumes', 4, '--recovery-volumes', 2,
                         '--no-metadata', '--threads', threads, '--progress')
            stats = json.loads(next(line.split('\t', 1)[1] for line in result.stderr.splitlines() if line.startswith('RZTIMING1\t')))
            stripes = layout(archive)[3]
            ceiling = threads if isinstance(threads, int) else 64
            self.assertLessEqual(stats['recovery_workers'], min(ceiling, stripes))
            self.assertLessEqual(stats['recovery_estimated_bytes'], 256 * 1024 * 1024)
            self.assertLessEqual(stats['recovery_peak_jobs'], 2 * stats['recovery_workers'])
            self.assertLessEqual(stats['volume_write_workers'], min(ceiling, 4, 6))
            if threads == 1: self.assertEqual(stats['volume_write_workers'], 1)
            if threads == 4: self.assertGreater(stats['volume_write_workers'], 1)
            archives.append(archive)
        self.assertEqual(payload(archives[0]), payload(archives[1]))
        self.assertEqual(payload(archives[0]), payload(archives[2]))

    def test_encryption_and_keyless_repair(self):
        for suite in ('standard', 'dual'):
            if suite == 'dual' and not json.loads(run('--capabilities').stdout)['aes256gcm']: continue
            archive = self.work / suite
            run('create', self.source, archive, '--data-volumes', 3, '--recovery-volumes', 2,
                '--encrypt', '--password-stdin', '--encryption', suite, input='test secret\n')
            self.assertTrue(info(archive)['locked'])
            (archive / 'd000000.rzv').unlink(); (archive / 'p000001.rzr').unlink()
            fixed = self.work / f'{suite}-fixed'; run('repair', archive, fixed)
            output = self.work / f'{suite}-out'
            run('extract', fixed, output, '--password-stdin', input='test secret\n')
            self.assertEqual((output / 'data').read_bytes(), self.data)
        keyed = self.work / 'keyed.rz'
        run('create', self.source, keyed, '--profile', 4, '--generate-key-file', '--encryption', 'standard')
        (keyed / 'd000000.rzv').unlink(); (keyed / 'd000001.rzv').unlink()
        fixed = self.work / 'key-fixed.rz'; run('repair', keyed, fixed)
        run('extract', fixed, self.work / 'key-output', '--key-file', self.work / 'keyed.rzkey')
        self.assertEqual((self.work / 'key-output' / 'data').read_bytes(), self.data)

    def test_many_volumes_with_bounded_descriptors(self):
        def limit(): resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
        archive = self.work / 'wide'
        run('create', self.source, archive, '--data-volumes', 32, '--recovery-volumes', 16, '--threads', 4, preexec_fn=limit)
        for file in sorted(archive.glob('*.rzv'))[:16]: file.unlink()
        run('repair', archive, self.work / 'wide-fixed', preexec_fn=limit)
        run('extract', self.work / 'wide-fixed', self.work / 'wide-out', preexec_fn=limit)
        self.assertEqual((self.work / 'wide-out' / 'data').read_bytes(), self.data)

    def test_parallel_finalization_failure_cleans_staging(self):
        reference = self.work / 'reference'
        run('create', self.source, reference, '--data-volumes', 1, '--recovery-volumes', 1,
            '--no-metadata', '--threads', 4)
        raw, _, _, stripes, _ = layout(reference)
        # The spool and temporary payload fit; final volumes include two indexes
        # and must fail during their concurrent envelope writes.
        limit = stripes * BLOCK + 100
        self.assertLess(limit, 2 * HEADER + 2 * len(raw) + stripes * BLOCK)
        def constrain():
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        output = self.work / 'failed'
        run('create', self.source, output, '--data-volumes', 1, '--recovery-volumes', 1,
            '--no-metadata', '--threads', 4, code=1, preexec_fn=constrain)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_invalid_counts_and_conflicting_options(self):
        for args in (('--data-volumes', 4), ('--recovery-volumes', 2),
                     ('--data-volumes', 0, '--recovery-volumes', 1),
                     ('--data-volumes', 101, '--recovery-volumes', 1),
                     ('--data-volumes', 4, '--recovery-volumes', 5),
                     ('--data-volumes', 4, '--recovery-volumes', 0),
                     ('--data-volumes', '2.5', '--recovery-volumes', 1),
                     ('--data-volumes', '-2', '--recovery-volumes', 1),
                     ('--data-volumes', 4, '--recovery-volumes', 2, '--profile', 3),
                     ('--profile', 4, '--volume-size', '1MiB'),
                     ('--profile', 4, '--recovery-percent', 20),
                     ('--profile', 4, '--recovery-bytes', '1MiB')):
            run('create', self.source, self.work / 'invalid', *args, code=1)
            self.assertFalse((self.work / 'invalid').exists())


if __name__ == '__main__': unittest.main()
