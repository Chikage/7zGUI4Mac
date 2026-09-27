#!/usr/bin/env python3
"""Profile 5: protected index pages, redundant bootstrap and legacy CLI defaults."""
import itertools
import hashlib
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
import tarfile
import tempfile
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
BLOCK, HEADER, RECORD = 65536, 120, 65568
CONTENT_LIMIT = 1024 ** 4


def run(*args, code=0, **kwargs):
    result = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, timeout=180, **kwargs)
    if result.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def volumes(path):
    return sorted([*path.glob('*.rzv'), *path.glob('*.rzr')])


def info(path, *args):
    return json.loads(run('list', path, '--json', '--no-auto-key-file', *args).stdout)


def layout(path):
    with volumes(path)[0].open('rb') as file:
        header = file.read(HEADER)
        assert header[:8] == b'RZVOL005'
        bootstrap_size, payload_size = struct.unpack_from('<QQ', header, 40)
        bootstrap = file.read(bootstrap_size)
    assert bootstrap[:8] == b'RZIDX005'
    profile, block, frame, k, m = struct.unpack_from('<IIIII', bootstrap, 24)
    stream, data_records, index_records = struct.unpack_from('<QQQ', bootstrap, 44)
    hash_pages, root_size = struct.unpack_from('<IQ', bootstrap, 68)
    assert (profile, block, frame) == (5, BLOCK, 4194304)
    assert payload_size == (data_records + index_records) * RECORD
    assert hash_pages == (data_records * (k + m) * 32 + BLOCK - 1) // BLOCK
    assert root_size == 44 + hash_pages * 32
    assert index_records == (hash_pages * BLOCK + root_size + k * BLOCK - 1) // (k * BLOCK)
    return {
        'bootstrap': bootstrap_size, 'k': k, 'm': m, 'stream': stream,
        'data': data_records, 'index': index_records,
        'index_offset': HEADER + bootstrap_size + data_records * RECORD,
        'payload_offset': HEADER + bootstrap_size,
    }


def flip(path, offset, count=1):
    with path.open('r+b') as file:
        file.seek(offset)
        original = file.read(count)
        assert len(original) == count
        file.seek(offset)
        file.write(bytes(byte ^ 0xa5 for byte in original))


class PaginatedIndexTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='rz-paginated-')
        cls.root = Path(cls.tmp.name)
        cls.source = cls.root / 'source'
        cls.source.mkdir()
        cls.data = random.Random(5209).randbytes(1024 * 1024 + 317)
        (cls.source / 'data').write_bytes(cls.data)
        (cls.source / 'data').chmod(0o640)
        (cls.source / 'empty').mkdir()
        cls.archive = cls.root / 'original'
        run('create', cls.source, cls.archive, '--profile', 5, '--data-volumes', 4, '--recovery-volumes', 2)
        cls.original = {file.name: file.read_bytes() for file in cls.archive.iterdir()}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.root))

    def tearDown(self):
        shutil.rmtree(self.work)

    def damaged(self):
        target = self.work / 'damaged'
        shutil.copytree(self.archive, target)
        return target

    def check_repair(self, broken, *, env=None):
        fixed = self.work / 'fixed'
        run('verify', broken, code=2)
        run('repair', broken, fixed, env=env)
        self.assertEqual({file.name: file.read_bytes() for file in fixed.iterdir()}, self.original)
        run('verify', fixed)
        output = self.work / 'output'
        run('extract', fixed, output)
        self.assertEqual((output / 'data').read_bytes(), self.data)
        self.assertEqual((output / 'data').stat().st_mode & 0o777, 0o640)
        self.assertTrue((output / 'empty').is_dir())
        shutil.rmtree(fixed)
        shutil.rmtree(output)

    def test_explicit_profile_and_legacy_defaults(self):
        self.assertEqual(info(self.archive)['recovery']['profile'], 5)
        for name, args, expected in [
            ('default', [], 3),
            ('counted', ['--data-volumes', 4, '--recovery-volumes', 2], 4),
            ('explicit4', ['--profile', 4], 4),
            ('explicit5', ['--profile', 5], 5),
        ]:
            archive = self.work / name
            run('create', self.source, archive, *args)
            self.assertEqual(info(archive)['recovery']['profile'], expected)

    def test_frozen_profile5_fixture_remains_readable(self):
        archive = self.work / 'frozen'
        archive.mkdir()
        with tarfile.open(Path(__file__).parent / 'fixtures' / 'profile5.tar.gz') as fixture:
            for member in fixture:
                self.assertTrue(member.isfile())
                self.assertEqual(Path(member.name).name, member.name)
                with fixture.extractfile(member) as source:
                    (archive / member.name).write_bytes(source.read())
        details = info(archive)['recovery']
        self.assertEqual((details['profile'], details['dataVolumes'], details['recoveryVolumes']), (5, 2, 1))
        run('verify', archive)
        output = self.work / 'frozen-output'
        run('extract', archive, output)
        self.assertEqual((output / 'legacy.txt').read_bytes(), b'RZ profile 5 compatibility fixture\n')

    def test_profile4_sidecar_in_profile5_set_is_rejected(self):
        legacy = self.work / 'legacy'
        run('create', self.source, legacy, '--profile', 4, '--data-volumes', 4, '--recovery-volumes', 2)
        broken = self.damaged()
        shutil.copyfile(legacy / 'manifest.rzm', broken / 'manifest.rzm')
        self.assertIn('Mixed archive IDs or profiles', run('list', broken, '--json', code=1).stderr)
        run('repair', broken, self.work / 'failed', code=1)
        self.assertFalse((self.work / 'failed').exists())

    def test_profile4_volume_in_profile5_set_is_rejected(self):
        legacy = self.work / 'legacy'
        run('create', self.source, legacy, '--profile', 4, '--data-volumes', 4, '--recovery-volumes', 2)
        broken = self.damaged()
        shutil.copyfile(legacy / 'd000000.rzv', broken / 'd000000.rzv')
        self.assertIn('Mixed archive IDs or profiles', run('list', broken, '--json', code=1).stderr)
        run('repair', broken, self.work / 'failed', code=1)
        self.assertFalse((self.work / 'failed').exists())

    def test_all_two_volume_losses_are_byte_exact_without_sidecar(self):
        for lost in itertools.combinations([file.name for file in volumes(self.archive)], 2):
            with self.subTest(lost=lost):
                broken = self.damaged()
                for name in (*lost, 'manifest.rzm'):
                    (broken / name).unlink()
                self.check_repair(broken)
                shutil.rmtree(broken)

    def test_equal_sizes_and_index_geometry(self):
        small = self.work / 'small'
        small.mkdir()
        (small / 'one').write_bytes(b'x')
        for k, m in ((1, 1), (3, 1), (10, 2), (100, 100)):
            archive = self.work / f'{k}-{m}'
            run('create', small, archive, '--profile', 5, '--data-volumes', k, '--recovery-volumes', m)
            details, dimensions = info(archive)['recovery'], layout(archive)
            metadata = 2 * HEADER + 2 * dimensions['bootstrap'] + 32 * dimensions['data'] + RECORD * dimensions['index']
            size = dimensions['data'] * BLOCK + metadata
            self.assertEqual({file.stat().st_size for file in volumes(archive)}, {size})
            self.assertEqual(len(volumes(archive)), k + m)
            self.assertEqual(details['metadataBytesPerVolume'], metadata)
            self.assertEqual(details['volumeSizeBytes'], size)
            self.assertEqual(details['contentLimitBytes'], CONTENT_LIMIT)
            self.assertEqual(details['toleratedVolumeLosses'], m)
        empty = self.work / 'empty'
        empty.mkdir()
        run('create', empty, self.work / 'empty-set', '--profile', 5)
        run('extract', self.work / 'empty-set', self.work / 'empty-out')
        self.assertEqual(list((self.work / 'empty-out').iterdir()), [])

    def test_damaged_index_shards_are_recovered_without_sidecar(self):
        broken = self.damaged()
        dimensions = layout(broken)
        (broken / 'manifest.rzm').unlink()
        for name in ('d000000.rzv', 'd000001.rzv'):
            for record in range(dimensions['index']):
                flip(broken / name, dimensions['index_offset'] + record * RECORD, RECORD)
        self.check_repair(broken)

    def test_multiple_index_pages_recover_from_alternating_shards(self):
        source = self.work / 'large-source'
        source.mkdir()
        generator = random.Random(551)
        expected = hashlib.sha256()
        with (source / 'large').open('wb') as file:
            for _ in range(17):
                block = generator.randbytes(4 * 1024 * 1024)
                file.write(block)
                expected.update(block)
        archive = self.work / 'large'
        run('create', source, archive, '--profile', 5, '--data-volumes', 1, '--recovery-volumes', 1,
            '--no-metadata', '--threads', 4)
        dimensions = layout(archive)
        self.assertGreaterEqual(dimensions['index'], 3)
        (archive / 'manifest.rzm').unlink()
        shards = volumes(archive)
        for record in range(dimensions['index']):
            flip(shards[record % len(shards)], dimensions['index_offset'] + record * RECORD)
        run('verify', archive, code=2)
        fixed = self.work / 'large-fixed'
        run('repair', archive, fixed)
        run('extract', fixed, self.work / 'large-out')
        actual = hashlib.sha256()
        with (self.work / 'large-out' / 'large').open('rb') as file:
            for block in iter(lambda: file.read(4 * 1024 * 1024), b''):
                actual.update(block)
        self.assertEqual(actual.digest(), expected.digest())

    def test_local_digest_damage_and_missing_volume_share_index_budget(self):
        broken = self.damaged()
        dimensions = layout(broken)
        (broken / 'd000000.rzv').unlink()
        (broken / 'manifest.rzm').unlink()
        flip(broken / 'p000000.rzr', dimensions['index_offset'] + BLOCK, 32)
        self.check_repair(broken, env={**os.environ, 'GF_COMPLETE_DISABLE_NEON': '1'})

    def test_mixed_data_and_index_damage(self):
        broken = self.damaged()
        dimensions = layout(broken)
        (broken / 'd000000.rzv').unlink()
        for stripe in range(dimensions['data']):
            remaining = volumes(broken)
            flip(remaining[stripe % len(remaining)], dimensions['payload_offset'] + stripe * RECORD)
        flip(broken / 'd000001.rzv', dimensions['index_offset'])
        self.check_repair(broken)

    def test_footer_bootstrap_fallback(self):
        broken = self.damaged()
        dimensions = layout(broken)
        (broken / 'manifest.rzm').unlink()
        for file in volumes(broken):
            flip(file, 0, HEADER + dimensions['bootstrap'])
        self.check_repair(broken)
        for file in volumes(broken):
            flip(file, file.stat().st_size - HEADER - dimensions['bootstrap'], HEADER + dimensions['bootstrap'])
        run('repair', broken, self.work / 'failed', code=1)
        self.assertFalse((self.work / 'failed').exists())

    def test_index_record_from_another_archive_is_rejected_and_repaired(self):
        other = self.work / 'other'
        run('create', self.source, other, '--profile', 5, '--data-volumes', 4, '--recovery-volumes', 2)
        broken = self.damaged()
        offset = layout(broken)['index_offset']
        with (other / 'd000000.rzv').open('rb') as source:
            source.seek(offset)
            substituted = source.read(RECORD)
        with (broken / 'd000000.rzv').open('r+b') as target:
            target.seek(offset)
            target.write(substituted)
        self.check_repair(broken)

    def test_truncated_volume_and_missing_volume(self):
        broken = self.damaged()
        (broken / 'd000000.rzv').unlink()
        with (broken / 'd000001.rzv').open('r+b') as file:
            file.truncate(HEADER + 17)
        self.check_repair(broken)

    def test_excessive_index_loss_is_not_published(self):
        broken = self.damaged()
        dimensions = layout(broken)
        for file in volumes(broken)[:3]:
            flip(file, dimensions['index_offset'], RECORD * dimensions['index'])
        result = subprocess.run([BIN, 'verify', str(broken)], capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        run('repair', broken, self.work / 'failed', code=1)
        self.assertFalse((self.work / 'failed').exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_encrypted_index_and_keyless_repair(self):
        for suite in ('standard', 'dual'):
            if suite == 'dual' and not json.loads(run('--capabilities').stdout)['aes256gcm']:
                continue
            archive = self.work / suite
            run('create', self.source, archive, '--profile', 5, '--data-volumes', 3, '--recovery-volumes', 2,
                '--encrypt', '--password-stdin', '--encryption', suite, input='paged secret\n')
            self.assertTrue(info(archive)['locked'])
            run('verify', archive, '--password-stdin', input='paged secret\n')
            run('extract', archive, self.work / f'{suite}-bad', '--password-stdin', input='incorrect\n', code=4)
            self.assertFalse((self.work / f'{suite}-bad').exists())
            dimensions = layout(archive)
            (archive / 'd000000.rzv').unlink()
            (archive / 'manifest.rzm').unlink()
            flip(archive / 'p000001.rzr', dimensions['index_offset'])
            fixed = self.work / f'{suite}-fixed'
            run('repair', archive, fixed)
            run('extract', fixed, self.work / f'{suite}-out', '--password-stdin', input='paged secret\n')
            self.assertEqual((self.work / f'{suite}-out' / 'data').read_bytes(), self.data)

    def test_generated_key_survives_repair(self):
        archive = self.work / 'keyed.rz'
        run('create', self.source, archive, '--profile', 5, '--generate-key-file', '--encryption', 'standard')
        key = self.work / 'keyed.rzkey'
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        self.assertTrue(info(archive)['requiresKeyFile'])
        self.assertFalse(json.loads(run('list', archive, '--json').stdout)['locked'])
        run('verify', archive, '--auto-key-file')
        dimensions = layout(archive)
        (archive / 'd000000.rzv').unlink()
        flip(archive / 'd000001.rzv', dimensions['index_offset'])
        fixed = self.work / 'key-fixed.rz'
        run('repair', archive, fixed)
        self.assertFalse(json.loads(run('list', fixed, '--json').stdout)['locked'])
        run('extract', fixed, self.work / 'key-out', '--key-file', key)
        self.assertEqual((self.work / 'key-out' / 'data').read_bytes(), self.data)

    def test_wide_archive_with_bounded_descriptors(self):
        def limit():
            resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
        archive = self.work / 'wide'
        run('create', self.source, archive, '--profile', 5, '--data-volumes', 32, '--recovery-volumes', 16,
            '--threads', 4, preexec_fn=limit)
        for file in sorted(archive.glob('*.rzv'))[:16]:
            file.unlink()
        run('repair', archive, self.work / 'wide-fixed', preexec_fn=limit)
        run('extract', self.work / 'wide-fixed', self.work / 'wide-out', preexec_fn=limit)
        self.assertEqual((self.work / 'wide-out' / 'data').read_bytes(), self.data)

    def test_cancellation_leaves_no_archive_or_key(self):
        source = self.work / 'cancel-source'
        source.mkdir()
        (source / 'data').write_bytes(random.Random(639).randbytes(24 * 1024 * 1024))
        archive = self.work / 'cancelled.rz'
        process = subprocess.Popen(
            [BIN, 'create', str(source), str(archive), '--profile', '5', '--generate-key-file',
             '--encryption', 'standard', '--progress'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertIn(b'RZPROGRESS1', process.stderr.readline())
        process.send_signal(signal.SIGINT)
        process.communicate(timeout=30)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(archive.exists())
        self.assertFalse((self.work / 'cancelled.rzkey').exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_conflicting_options_are_rejected(self):
        for args in (
            ('--profile', 5, '--volume-size', '1MiB'),
            ('--profile', 5, '--recovery-percent', 20),
            ('--profile', 5, '--recovery-bytes', '1MiB'),
            ('--profile', 5, '--data-volumes', 4),
            ('--profile', 5, '--data-volumes', 4, '--recovery-volumes', 5),
            ('--profile', 5, '--data-volumes', 0, '--recovery-volumes', 1),
            ('--profile', 5, '--data-volumes', 101, '--recovery-volumes', 1),
        ):
            run('create', self.source, self.work / 'invalid', *args, code=1)
            self.assertFalse((self.work / 'invalid').exists())


if __name__ == '__main__':
    unittest.main()
