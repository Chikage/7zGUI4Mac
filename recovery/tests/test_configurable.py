#!/usr/bin/env python3
"""Profile-2 integration: arbitrary caps/budgets, layout-aware fault injection, v1 compatibility."""
import hashlib
import json
import math
import os
from pathlib import Path
import random
import resource
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
BLOCK, HEADER = 65536, 120

def run(*args, code=0, env=None):
    args = list(args)
    if args[0] == 'create': args += ['--profile', '2']
    elif args[0] == 'create-selected':
        index = args.index('--'); args[index:index] = ['--profile', '2']
    p = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, env=env)
    if p.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p

def tree(path):
    return {str(p.relative_to(path)): None if p.is_dir() else hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.rglob('*'))}

def layout(path):
    raw = (path / 'manifest.rzm').read_bytes()[:-32]
    assert raw[:8] == b'RZIDX002'
    cap = struct.unpack_from('<I', raw, 56)[0]
    data, parity = struct.unpack_from('<QQ', raw, 68)
    count = struct.unpack_from('<I', raw, 84)[0]
    groups, position, dstart, pstart = [], 88, 0, 0
    for _ in range(count):
        k, m = struct.unpack_from('<II', raw, position)
        groups.append((k, m, dstart, pstart))
        position += 8 + 32 * (k + m)
        dstart += k
        pstart += m
    return len(raw), math.ceil(data / cap), math.ceil(parity / cap), groups

def cell(path, info, group, shard):
    length, dv, pv, groups = info
    k, _, ds, ps = groups[group]
    parity = shard >= k
    logical = ps + shard - k if parity else ds + shard
    count = pv if parity else dv
    name = f'p{logical % count:06}.rzr' if parity else f'd{logical % count:06}.rzv'
    return path / name, HEADER + length + (logical // count) * BLOCK

def flip(path, offset, length=1):
    with path.open('r+b') as f:
        f.seek(offset); data = f.read(length); assert len(data) == length
        f.seek(offset); f.write(bytes(x ^ 0xA5 for x in data))

class ConfigurableTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='rz-v2-')
        cls.root = Path(cls.tmp.name)
        cls.src = cls.root / 'source'
        (cls.src / '空目录').mkdir(parents=True)
        (cls.src / '含"引号.txt').write_text('可恢复数据\n')
        (cls.src / 'empty').touch()
        (cls.src / 'random.bin').write_bytes(random.Random(919).randbytes(9 * 1024 * 1024 + 319))
        cls.archive = cls.root / 'archive.rz'
        run('create', cls.src, cls.archive, '--volume-size', '1MiB', '--recovery-percent', '20')
        cls.expected = tree(cls.src)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.root))

    def tearDown(self):
        shutil.rmtree(self.work)

    def damaged(self, source=None):
        dest = self.work / 'damaged.rz'
        shutil.copytree(source or self.archive, dest)
        return dest

    def check_repair(self, broken, original=None, scalar=False):
        out = self.work / 'repaired.rz'
        run('repair', broken, out, env={**os.environ, 'GF_COMPLETE_DISABLE_NEON': '1'} if scalar else None)
        run('verify', out)
        self.assertEqual(tree(out), tree(original or self.archive))
        run('extract', out, self.work / 'extracted')
        self.assertEqual(tree(self.work / 'extracted'), self.expected)

    def test_custom_percentage_and_caps_roundtrip(self):
        counts = []
        for cap, percent in [('1MiB', '1'), ('1.5MiB', '7.5'), ('3MiB', '33.33'), ('1.25GiB', '100')]:
            with self.subTest(cap=cap, percent=percent):
                out = self.work / cap
                run('create', self.src, out, '--volume-size', cap, '--recovery-percent', percent)
                info = json.loads(run('list', out, '--json').stdout)['recovery']
                expected_blocks = math.ceil((info['dataBytes'] // BLOCK) * int(percent.replace('.', '').ljust(len(percent.split('.')[0]) + 2, '0')) / 10000)
                self.assertEqual(info['payloadBytes'], expected_blocks * BLOCK)
                self.assertEqual(info['requestedValue'], round(float(percent) * 100))
                self.assertTrue(all(p.stat().st_size <= info['volumeLimitBytes'] for p in [*out.glob('*.rzv'), *out.glob('*.rzr')]))
                self.assertEqual(len(list(out.glob('*.rzv'))), info['dataVolumes'])
                run('verify', out)
                extracted = self.work / ('out-' + cap)
                run('extract', out, extracted)
                self.assertEqual(tree(extracted), self.expected)
                counts.append(info['dataVolumes'])
        self.assertGreater(counts[0], counts[-1])

    def test_recovery_bytes_and_capacity_errors(self):
        out = self.work / 'bytes'
        run('create', self.src, out, '--volume-size', '1.5MiB', '--recovery-bytes', '500KiB')
        info = json.loads(run('list', out, '--json').stdout)['recovery']
        self.assertEqual(info['payloadBytes'], 8 * BLOCK)
        self.assertEqual(info['requestedMode'], 1)
        self.assertEqual(info['requestedValue'], 500 * 1024)
        for value in ['1B', '20MiB']:
            failed = self.work / value
            run('create', self.src, failed, '--recovery-bytes', value, code=1)
            self.assertFalse(failed.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_maximum_erasures_per_group(self):
        broken = self.damaged(); info = layout(broken)
        rng = random.Random(26)
        for g, (k, m, _, _) in enumerate(info[3]):
            for shard in rng.sample(range(k + m), m):
                path, offset = cell(broken, info, g, shard)
                flip(path, offset + rng.randrange(BLOCK))
        run('verify', broken, code=2)
        self.check_repair(broken, scalar=True)

    def test_over_capacity_rejected_without_output(self):
        broken = self.damaged(); info = layout(broken)
        _, m, _, _ = info[3][0]
        for shard in range(m + 1):
            path, offset = cell(broken, info, 0, shard); flip(path, offset)
        run('verify', broken, code=3)
        out = self.work / 'failed'
        run('repair', broken, out, code=1)
        self.assertFalse(out.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_one_data_volume_loss(self):
        broken = self.damaged()
        (broken / 'd000000.rzv').unlink()
        run('verify', broken, code=2)
        self.check_repair(broken)

    def test_low_percentage_cannot_claim_whole_volume_recovery(self):
        out = self.work / 'low'
        run('create', self.src, out, '--volume-size', '1MiB', '--recovery-percent', '1')
        (out / 'd000000.rzv').unlink()
        run('verify', out, code=3)
        run('repair', out, self.work / 'failed', code=1)

    def test_truncation(self):
        broken = self.damaged(); file = broken / 'd000000.rzv'
        with file.open('r+b') as f: f.truncate(HEADER + layout(broken)[0] + 17)
        run('verify', broken, code=2)
        self.check_repair(broken)

    def test_index_fallback_and_all_metadata_missing(self):
        broken = self.damaged(); length = layout(broken)[0]
        (broken / 'manifest.rzm').unlink()
        files = [*broken.glob('*.rzv'), *broken.glob('*.rzr')]
        for p in files: flip(p, 0, HEADER + length)
        run('list', broken, '--json')
        run('verify', broken, code=2)
        self.check_repair(broken)
        for p in files: flip(p, p.stat().st_size - HEADER - length, HEADER + length)
        run('verify', broken, code=1)

    def test_headers_lost_with_sidecar(self):
        broken = self.damaged()
        for p in [*broken.glob('*.rzv'), *broken.glob('*.rzr')]:
            flip(p, 0, HEADER); flip(p, p.stat().st_size - HEADER, HEADER)
        run('verify', broken, code=2)
        self.check_repair(broken)

    def test_missing_parity_does_not_block_extraction(self):
        broken = self.damaged()
        for p in broken.glob('*.rzr'): p.unlink()
        run('verify', broken, code=2)
        run('extract', broken, self.work / 'extracted')
        self.assertEqual(tree(self.work / 'extracted'), self.expected)

    def test_late_data_damage_does_not_publish_partial_extraction(self):
        broken = self.damaged(); info = layout(broken)
        last = len(info[3]) - 1
        path, offset = cell(broken, info, last, info[3][last][0] - 1)
        flip(path, offset)
        result = run('verify', broken, code=2)
        self.assertIn('bad_blocks=1 bad_data_blocks=1 unrecoverable_stripes=0', result.stdout)
        output = self.work / 'failed'
        result = run('extract', broken, output, code=1)
        self.assertIn('run repair first', result.stderr)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_mixed_archive_and_symlink_rejected(self):
        other = self.work / 'other'
        run('create', self.src, other, '--volume-size', '1MiB')
        broken = self.damaged()
        shutil.copyfile(other / 'd000000.rzv', broken / 'd000000.rzv')
        run('verify', broken, code=1)
        (broken / 'd000000.rzv').unlink()
        (broken / 'd000000.rzv').symlink_to(self.archive / 'd000000.rzv')
        run('verify', broken, code=1)

    def test_empty_and_single_block_rounding(self):
        src = self.work / 'empty'; src.mkdir()
        out = self.work / 'empty-set'
        run('create', src, out, '--recovery-percent', '1')
        info = json.loads(run('list', out, '--json').stdout)['recovery']
        self.assertEqual(info['dataBytes'], BLOCK)
        self.assertEqual(info['payloadBytes'], BLOCK)
        run('verify', out)
        run('extract', out, self.work / 'empty-out')
        self.assertEqual(tree(self.work / 'empty-out'), {})

    def test_selected_inputs_and_no_overwrite(self):
        out = self.work / 'selected.rz'
        run('create-selected', out, '--volume-size', '1.5MiB', '--recovery-percent', '7.5', '--', self.src, self.src / 'random.bin')
        entries = json.loads(run('list', out, '--json').stdout)['entries']
        self.assertEqual(sum(not e['isDirectory'] for e in entries), 3)
        original = tree(out)
        run('create', self.src, out, code=1)
        self.assertEqual(tree(out), original)
        run('create-selected', self.src / 'recursive.rz', '--', self.src, code=1)

    def test_invalid_options_rejected_before_creation(self):
        for options in [
            ['--recovery-percent', '0'], ['--recovery-percent', '100.01'], ['--recovery-percent', '7.123'],
            ['--volume-size', '0.5MiB'], ['--volume-size', '16.001GiB'], ['--volume-size', '-1'],
            ['--volume-size', 'NaN'], ['--volume-size', '1e3'], ['--volume-size', '1.2.3MiB'],
            ['--recovery-percent', '10', '--recovery-bytes', '1MiB'], ['--recovery-bytes', '0'],
        ]:
            with self.subTest(options=options):
                run('create', self.src, self.work / 'invalid', *options, code=1)
                self.assertFalse((self.work / 'invalid').exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_previous_binary_fixture_compatibility(self):
        old = self.work / 'old'; old.mkdir()
        fixture = Path(__file__).parent / 'fixtures' / 'profile1.tar.gz'
        with tarfile.open(fixture) as f:
            for member in f.getmembers():
                self.assertTrue(member.isfile() and '/' not in member.name and '..' not in member.name)
                (old / member.name).write_bytes(f.extractfile(member).read())
        run('verify', old)
        (old / 'g000000.d00.rzv').unlink()
        (old / 'g000000.p00.rzr').unlink()
        run('verify', old, code=2)
        run('repair', old, self.work / 'fixed')
        run('extract', self.work / 'fixed', self.work / 'out')
        self.assertEqual((self.work / 'out' / 'legacy.txt').read_text(), 'RZ profile 1 compatibility fixture\n')

    def test_many_volumes_with_bounded_file_descriptors(self):
        src = self.work / 'many-input'; src.mkdir()
        (src / 'large.bin').write_bytes(random.Random(89).randbytes(32 * 1024 * 1024))
        archive = self.work / 'many'
        run('create', src, archive, '--volume-size', '1MiB')
        self.assertGreater(len(list(archive.glob('*.rzv'))) + len(list(archive.glob('*.rzr'))), 32)
        info = layout(archive)
        for group in range(len(info[3])):
            path, offset = cell(archive, info, group, 0); flip(path, offset)
        def limit_fds(): resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
        result = subprocess.run([BIN, 'repair', str(archive), str(self.work / 'fixed')],
                                capture_output=True, text=True, preexec_fn=limit_fds)
        self.assertEqual(result.returncode, 0, result.stderr)
        run('extract', self.work / 'fixed', self.work / 'out')
        self.assertEqual(tree(src), tree(self.work / 'out'))

    def test_mixed_profile_sidecar_is_rejected(self):
        broken = self.damaged()
        with tarfile.open(Path(__file__).parent / 'fixtures' / 'profile1.tar.gz') as f:
            (broken / 'manifest.rzm').write_bytes(f.extractfile('manifest.rzm').read())
        result = run('verify', broken, code=1)
        self.assertIn('Mixed archive', result.stderr)

if __name__ == '__main__': unittest.main()
