#!/usr/bin/env python3
"""Black-box fault injection; no third-party Python dependencies."""
import hashlib
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
import time
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
BLOCK = 65536
HEADER = 120


def run(*args, code=0, env=None):
    # Preserve the original profile-1 regression suite after profile 2 becomes default.
    args = list(args)
    if args[0] == 'create':
        args += ['--profile', '1']
    elif args[0] == 'create-selected':
        index = args.index('--')
        args[index:index] = ['--profile', '1']
    result = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, env=env)
    if result.returncode != code:
        raise AssertionError(f"{args}: expected {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def tree(path):
    return {str(p.relative_to(path)): None if p.is_dir() else hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.rglob('*'))}


def volumes(path):
    return sorted([*path.glob('*.rzv'), *path.glob('*.rzr')])


def geometry(path):
    b = path.read_bytes()[:HEADER]
    manifest, payload = struct.unpack_from('<QQ', b, 40)
    return manifest, payload, HEADER + manifest


def flip(path, offset, length=1):
    with path.open('r+b') as f:
        f.seek(offset)
        b = f.read(length)
        assert len(b) == length
        f.seek(offset)
        f.write(bytes(x ^ 0xA5 for x in b))


class ArchiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='rz-tests-')
        cls.root = Path(cls.tmp.name)
        cls.input = cls.root / 'input'
        cls.input.mkdir()
        (cls.input / '空目录').mkdir()
        (cls.input / 'folder').mkdir()
        (cls.input / 'folder' / 'empty').touch()
        (cls.input / 'folder' / '中文 space.txt').write_text('恢复测试\n' * 2000)
        rng = random.Random(1907)
        # A >4 MiB incompressible file exercises independent frames and boundaries.
        (cls.input / 'random.bin').write_bytes(rng.randbytes(5 * 1024 * 1024 + 137))
        cls.archive = cls.root / 'archive'
        run('create', cls.input, cls.archive, '--volume-size', '1MiB')
        cls.expected = tree(cls.input)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.root, prefix='case-'))

    def tearDown(self):
        shutil.rmtree(self.work)

    def damaged(self):
        dest = self.work / 'damaged'
        shutil.copytree(self.archive, dest)
        return dest

    def repaired(self, archive):
        out = self.work / 'repaired'
        run('repair', archive, out)
        run('verify', out)
        # Exact volume bytes must match, not just extracted file contents.
        self.assertEqual(tree(out), tree(self.archive))
        run('extract', out, self.work / 'extracted')
        self.assertEqual(tree(self.work / 'extracted'), self.expected)

    def test_roundtrip_and_volume_cap(self):
        run('verify', self.archive)
        self.assertEqual(len(volumes(self.archive)), 12)
        self.assertTrue(all(p.stat().st_size <= 1024 * 1024 for p in volumes(self.archive)))
        listing = run('list', self.archive).stdout
        self.assertIn('中文 space.txt', listing)
        run('extract', self.archive, self.work / 'out')
        self.assertEqual(tree(self.work / 'out'), self.expected)

    def test_selected_inputs_and_json_listing(self):
        src = self.work / 'source'
        (src / 'left').mkdir(parents=True)
        (src / 'right').mkdir()
        left = src / 'left' / 'same.txt'
        right = src / 'right' / 'same.txt'
        quoted = src / 'right' / '含"引号.txt'
        left.write_text('left')
        right.write_text('right')
        quoted.write_text('quoted')
        (src / 'right' / 'not-selected.txt').write_text('excluded')
        archive = src / 'selected.rz'
        run('create-selected', archive, '--volume-size', '1MiB', '--', left.parent, left, right, quoted, right)
        listing = json.loads(run('list', archive, '--json').stdout)
        self.assertEqual(listing['version'], 1)
        self.assertEqual({e['path'] for e in listing['entries'] if not e['isDirectory']},
                         {'left/same.txt', 'right/same.txt', 'right/含"引号.txt'})
        run('verify', archive)
        run('extract', archive, self.work / 'selected-output')
        self.assertEqual((self.work / 'selected-output' / 'right' / 'same.txt').read_text(), 'right')
        run('create-selected', src / 'recursive.rz', '--volume-size', '1MiB', '--', src, code=1)
        link = src / 'link'
        link.symlink_to(left)
        run('create-selected', self.work / 'symlink.rz', '--volume-size', '1MiB', '--', link, code=1)

    def test_custom_volume_cap_and_fixed_recovery_ratio(self):
        src = self.work / 'custom-input'
        src.mkdir()
        (src / 'large.bin').write_bytes(random.Random(27).randbytes(12 * 1024 * 1024 + 19))
        counts = []
        for cap in (1024 * 1024, 1572864, 3 * 1024 * 1024):
            archive = self.work / f'cap-{cap}'
            run('create', src, archive, '--volume-size', cap)
            files = volumes(archive)
            self.assertTrue(all(p.stat().st_size <= cap for p in files))
            data = [p for p in files if p.suffix == '.rzv']
            parity = [p for p in files if p.suffix == '.rzr']
            self.assertEqual(len(data), 5 * len(parity))
            self.assertEqual(sum(geometry(p)[1] for p in data), 5 * sum(geometry(p)[1] for p in parity))
            counts.append(len(files))
            run('verify', archive)
        self.assertGreater(counts[0], counts[-1])
        run('create', src, self.work / 'unsupported-ratio', '--recovery-percent', 10, code=1)
        self.assertFalse((self.work / 'unsupported-ratio').exists())

    def test_all_two_volume_losses(self):
        # Every pair: data+data, data+parity, parity+parity. All original files stay untouched.
        archive = self.damaged()
        paths = volumes(archive)
        for a, b in itertools.combinations(paths, 2):
            with self.subTest(a=a.name, b=b.name):
                a.rename(a.with_suffix('.hidden'))
                b.rename(b.with_suffix('.hidden'))
                run('verify', archive, code=2)
                out = self.work / 'pair'
                run('repair', archive, out)
                self.assertEqual(tree(out), tree(self.archive))
                shutil.rmtree(out)
                a.with_suffix('.hidden').rename(a)
                b.with_suffix('.hidden').rename(b)

    def test_random_corruption(self):
        archive = self.damaged()
        paths = volumes(archive)
        rng = random.Random(91)
        _, payload, offset = geometry(paths[0])
        for stripe in range(payload // BLOCK):
            for path in rng.sample(paths, 2):
                flip(path, offset + stripe * BLOCK + rng.randrange(BLOCK))
        run('verify', archive, code=2)
        self.repaired(archive)

    def test_contiguous_damage(self):
        archive = self.damaged()
        p = archive / 'g000000.d03.rzv'
        _, payload, offset = geometry(p)
        flip(p, offset + BLOCK - 50, min(3 * BLOCK, payload - BLOCK))
        run('verify', archive, code=2)
        self.repaired(archive)

    def test_truncation_and_missing_volume(self):
        archive = self.damaged()
        p = archive / 'g000000.d00.rzv'
        _, _, offset = geometry(p)
        with p.open('r+b') as f:
            f.truncate(offset + BLOCK + 13)
        (archive / 'g000000.d09.rzv').unlink()
        run('verify', archive, code=2)
        self.repaired(archive)

    def test_manifest_fallback(self):
        archive = self.damaged()
        (archive / 'manifest.rzm').unlink()
        # All front headers and front index copies gone: recover from volume tails.
        for p in volumes(archive):
            meta, _, _ = geometry(p)
            flip(p, 0, HEADER + meta)
        run('verify', archive, code=2)
        run('list', archive)
        self.repaired(archive)

    def test_payload_salvage_without_volume_headers(self):
        archive = self.damaged()
        for p in volumes(archive):
            flip(p, 0, HEADER)
            flip(p, p.stat().st_size - HEADER, HEADER)
        run('verify', archive, code=2)
        self.repaired(archive)

    def test_no_manifest_survives(self):
        archive = self.damaged()
        (archive / 'manifest.rzm').unlink()
        for p in volumes(archive):
            meta, payload, _ = geometry(p)
            flip(p, HEADER, meta)
            flip(p, HEADER + meta + payload, meta)
        self.assertIn('No valid manifest', run('verify', archive, code=1).stderr)
        run('repair', archive, self.work / 'out', code=1)
        self.assertFalse((self.work / 'out').exists())

    def test_three_bad_blocks_same_stripe(self):
        archive = self.damaged()
        for p in volumes(archive)[:3]:
            flip(p, geometry(p)[2] + 23)
        run('verify', archive, code=3)
        run('repair', archive, self.work / 'out', code=1)
        self.assertFalse((self.work / 'out').exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_lost_two_volumes_plus_bad_block(self):
        archive = self.damaged()
        paths = volumes(archive)
        paths[0].unlink()
        paths[1].unlink()
        flip(paths[2], geometry(paths[2])[2])
        run('verify', archive, code=3)

    def test_mixed_archive_rejected(self):
        archive = self.damaged()
        other = self.work / 'other'
        run('create', self.input, other, '--volume-size', '1MiB')
        shutil.copyfile(other / 'g000000.d01.rzv', archive / 'g000000.d01.rzv')
        self.assertIn('Mixed archive', run('verify', archive, code=1).stderr)

    def test_no_overwrite_or_source_mutation(self):
        before = tree(self.archive)
        out = self.work / 'exists'
        out.mkdir()
        (out / 'sentinel').write_text('keep')
        for command in ('extract', 'repair'):
            run(command, self.archive, out, code=1)
        run('create', self.input, out, code=1)
        self.assertEqual((out / 'sentinel').read_text(), 'keep')
        self.assertEqual(tree(self.archive), before)
        run('create', self.input, self.input / 'nested-set', code=1)

    def test_symlinks_rejected(self):
        src = self.work / 'source'
        src.mkdir()
        (src / 'link').symlink_to(self.input / 'random.bin')
        run('create', src, self.work / 'out', code=1)
        archive = self.damaged()
        p = archive / 'g000000.d00.rzv'
        p.unlink()
        p.symlink_to(self.archive / p.name)
        run('verify', archive, code=1)

    def test_empty_directory_archive(self):
        src = self.work / 'empty'
        src.mkdir()
        archive = self.work / 'empty-set'
        run('create', src, archive)
        run('verify', archive)
        run('extract', archive, self.work / 'out')
        self.assertEqual(tree(self.work / 'out'), {})

    def test_extract_without_parity(self):
        archive = self.damaged()
        for p in archive.glob('*.rzr'):
            p.unlink()
        run('verify', archive, code=2)
        run('extract', archive, self.work / 'out')
        self.assertEqual(tree(self.work / 'out'), self.expected)

    def test_multiple_groups_and_cross_group_frame(self):
        src = self.work / 'source'
        src.mkdir()
        (src / 'large.bin').write_bytes((self.input / 'random.bin').read_bytes() * 3)
        archive = self.work / 'set'
        run('create', src, archive, '--volume-size', '1MiB')
        self.assertGreater(len(volumes(archive)), 12)
        self.assertTrue(all(p.stat().st_size <= 1024 * 1024 for p in volumes(archive)))
        for p in archive.glob('*.d00.rzv'):
            p.unlink()
        for p in archive.glob('*.p01.rzr'):
            p.unlink()
        run('verify', archive, code=2)
        run('repair', archive, self.work / 'fixed')
        run('extract', self.work / 'fixed', self.work / 'out')
        self.assertEqual(tree(self.work / 'out'), tree(src))

    def test_scalar_backend_reads_neon_archive(self):
        archive = self.damaged()
        (archive / 'g000000.d00.rzv').unlink()
        (archive / 'g000000.p00.rzr').unlink()
        run('repair', archive, self.work / 'fixed', env={**os.environ, 'GF_COMPLETE_DISABLE_NEON': '1'})
        self.assertEqual(tree(self.work / 'fixed'), tree(self.archive))

    def test_write_failure_cleans_staging(self):
        def limit_file_size():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))
        out = self.work / 'out'
        result = subprocess.run([BIN, 'create', str(self.input), str(out)],
                                preexec_fn=limit_file_size, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Write failed', result.stderr)
        self.assertFalse(out.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_cancellation_cleans_staging(self):
        src = self.work / 'source'
        src.mkdir()
        with (src / 'sparse.bin').open('wb') as f:
            f.truncate(512 * 1024 * 1024)
        out = self.work / 'out'
        process = subprocess.Popen([BIN, 'create', str(src), str(out)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        while not list(self.work.glob('.rz-stage-*/compressed.tmp')) and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.001)
        process.send_signal(signal.SIGINT)
        _, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, error)
        self.assertIn('cancelled', error)
        self.assertFalse(out.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))


if __name__ == '__main__':
    unittest.main()
