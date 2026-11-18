#!/usr/bin/env python3
"""Single-file CLI, damaged envelopes/extents, legacy conversion and credentials."""
import hashlib
import json
from pathlib import Path
import random
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())


def run(*args, code=0, password=None):
    result = subprocess.run([BIN, *map(str, args)], input=password, text=True, capture_output=True, timeout=90)
    if result.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def layout(path):
    with path.open('rb') as file:
        header = file.read(128)
    assert header[:8] == b'RZCNT001'
    k, m = struct.unpack_from('<II', header, 12)
    bootstrap, volume, total = struct.unpack_from('<QQQ', header, 40)
    assert total == path.stat().st_size == 256 + bootstrap + 32 + (k + m) * volume
    first = 128 + bootstrap + 32
    members = {'manifest.rzm': (128, bootstrap + 32)}
    for column in range(k + m):
        name = f'd{column:06d}.rzv' if column < k else f'p{column - k:06d}.rzr'
        members[name] = (first + column * volume, volume)
    return members


def wipe(path, offset, length):
    with path.open('r+b') as file:
        file.seek(offset)
        file.write(bytes(length))


class ContainerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='rz-container-')
        cls.root = Path(cls.tmp.name)
        cls.source = cls.root / 'source'
        cls.source.mkdir()
        cls.data = random.Random(701).randbytes(600_000)
        (cls.source / '资料.bin').write_bytes(cls.data)
        (cls.source / 'empty').touch()
        (cls.source / 'folder').mkdir()
        cls.archive = cls.root / 'original.rz'
        run('create', cls.source, cls.archive, '--data-volumes', 4, '--recovery-volumes', 2, '--no-metadata')
        assert cls.archive.is_file()
        cls.members = layout(cls.archive)
        cls.original = cls.archive.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.root))

    def tearDown(self):
        self.assertFalse(list(self.work.glob('.rz-stage-*')))
        shutil.rmtree(self.work)

    def damaged(self):
        return Path(shutil.copyfile(self.archive, self.work / 'damaged.rz'))

    def check_repair(self, broken):
        digest = hashlib.sha256(broken.read_bytes()).digest()
        run('verify', broken, code=2)
        fixed = self.work / 'fixed.rz'
        run('repair', broken, fixed)
        self.assertTrue(fixed.is_file())
        self.assertEqual(fixed.read_bytes(), self.original)
        self.assertEqual(hashlib.sha256(broken.read_bytes()).digest(), digest)
        run('verify', fixed)
        output = self.work / 'out'
        run('extract', fixed, output)
        self.assertEqual((output / '资料.bin').read_bytes(), self.data)
        self.assertTrue((output / 'folder').is_dir())

    def test_default_and_selected_round_trip(self):
        self.assertEqual(self.original[:128], self.original[-128:])
        details = json.loads(run('list', self.archive, '--json').stdout)
        self.assertEqual(details['recovery']['dataVolumes'], 4)
        self.assertEqual(details['recovery']['recoveryVolumes'], 2)
        run('verify', self.archive)
        selected = self.work / 'selected.rz'
        run('create-selected', selected, '--', self.source / '资料.bin', self.source / 'empty')
        self.assertTrue(selected.is_file())
        output = self.work / 'out'
        run('extract', selected, output)
        self.assertEqual((output / '资料.bin').read_bytes(), self.data)
        self.assertEqual((output / 'empty').read_bytes(), b'')

    def test_empty_and_maximum_volume_counts(self):
        empty = self.work / 'empty'
        empty.mkdir()
        archive = self.work / 'empty.rz'
        run('create', empty, archive, '--data-volumes', 100, '--recovery-volumes', 100, '--no-metadata')
        self.assertEqual(len(layout(archive)), 201)
        run('verify', archive)
        run('extract', archive, self.work / 'out')
        self.assertEqual(list((self.work / 'out').iterdir()), [])

    def test_front_header_damage(self):
        broken = self.damaged()
        wipe(broken, 0, 128)
        run('list', broken, '--json')
        self.check_repair(broken)

    def test_footer_damage(self):
        broken = self.damaged()
        wipe(broken, broken.stat().st_size - 128, 128)
        self.check_repair(broken)

    def test_two_lost_extents_and_manifest(self):
        broken = self.damaged()
        for name in ('d000000.rzv', 'p000001.rzr', 'manifest.rzm'):
            wipe(broken, *self.members[name])
        self.check_repair(broken)

    def test_tail_truncation(self):
        broken = self.damaged()
        with broken.open('r+b') as file:
            file.truncate(self.members['p000001.rzr'][0] + 50)
        self.check_repair(broken)

    def test_too_many_lost_extents_does_not_publish(self):
        broken = self.damaged()
        for name in ('d000000.rzv', 'p000000.rzr', 'p000001.rzr'):
            wipe(broken, *self.members[name])
        run('verify', broken, code=3)
        run('repair', broken, self.work / 'failed.rz', code=1)
        self.assertFalse((self.work / 'failed.rz').exists())

    def test_invalid_and_conflicting_envelopes(self):
        broken = self.damaged()
        wipe(broken, 0, 128)
        wipe(broken, broken.stat().st_size - 128, 128)
        run('list', broken, code=1)
        run('repair', broken, self.work / 'failed.rz', code=1)
        self.assertFalse((self.work / 'failed.rz').exists())
        other = self.work / 'other.rz'
        run('create', self.source, other, '--data-volumes', 4, '--recovery-volumes', 2, '--no-metadata')
        broken.write_bytes(self.original)
        with broken.open('r+b') as file:
            file.seek(-128, 2)
            file.write(other.read_bytes()[-128:])
        self.assertIn('Conflicting RZ container headers', run('verify', broken, code=1).stderr)

    def test_legacy_round_trip_and_migration(self):
        legacy = self.work / 'legacy.rz'
        run('repair', self.archive, legacy, '--directory')
        self.assertTrue(legacy.is_dir())
        for name, (offset, size) in self.members.items():
            self.assertEqual((legacy / name).read_bytes(), self.original[offset:offset + size])
        run('verify', legacy)
        (legacy / 'd000000.rzv').unlink()
        self.check_repair_legacy(legacy)

    def check_repair_legacy(self, legacy):
        fixed = self.work / 'migrated.rz'
        run('repair', legacy, fixed)
        self.assertEqual(fixed.read_bytes(), self.original)
        run('verify', fixed)

    def test_password_and_key_file(self):
        for protection in ('password', 'key'):
            with self.subTest(protection=protection):
                archive = self.work / f'{protection}.rz'
                options = ['--encrypt', '--password-stdin'] if protection == 'password' else ['--generate-key-file']
                password = 'container-secret\n' if protection == 'password' else None
                run('create', self.source, archive, '--encryption', 'standard', '--no-metadata', *options, password=password)
                self.assertTrue(archive.is_file())
                credentials = ['--password-stdin'] if password else ['--auto-key-file']
                run('verify', archive, *credentials, password=password)
                if password:
                    run('extract', archive, self.work / 'wrong', '--password-stdin', password='wrong\n', code=4)
                    self.assertFalse((self.work / 'wrong').exists())
                else:
                    key = archive.with_suffix('.rzkey')
                    self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                    key.rename(self.work / 'renamed-key.rzkey')
                wipe(archive, *layout(archive)['d000000.rzv'])
                repaired = self.work / f'{protection}-repaired.rz'
                run('repair', archive, repaired)
                output = self.work / f'{protection}-out'
                run('extract', repaired, output, *credentials, password=password)
                self.assertEqual((output / '资料.bin').read_bytes(), self.data)

    def test_collisions_and_symlinks(self):
        output = self.work / 'exists.rz'
        output.write_bytes(b'keep')
        run('repair', self.archive, output, code=1)
        run('create', self.source, output, code=1)
        self.assertEqual(output.read_bytes(), b'keep')
        alias = self.work / 'alias.rz'
        alias.symlink_to(self.archive)
        run('verify', alias, code=1)

    def test_cancel_container_assembly(self):
        source = self.work / 'large'
        source.mkdir()
        with (source / 'data').open('wb') as file:
            for _ in range(32):
                file.write(self.data)
        output = self.work / 'cancelled.rz'
        process = subprocess.Popen([BIN, 'create', str(source), str(output), '--progress', '--no-metadata'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for line in process.stderr:
                if line.startswith('RZPROGRESS1\twriting\t'):
                    process.send_signal(signal.SIGTERM)
                    break
            stdout, stderr = process.communicate(timeout=60)
            self.assertNotEqual(process.returncode, 0, (stdout, stderr))
            self.assertFalse(output.exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
