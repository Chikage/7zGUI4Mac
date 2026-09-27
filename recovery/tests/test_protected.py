#!/usr/bin/env python3
"""Encryption, keyless repair, filesystem metadata, and backward compatibility."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
DUAL = '--dual' in sys.argv
if DUAL: sys.argv.remove('--dual')
PASSWORD = 'true'  # also catches accidental redaction of JSON boolean literals in clients
BLOCK, HEADER = 65536, 120
MAC = sys.platform == 'darwin'
if MAC:
    LIB = ctypes.CDLL(None, use_errno=True)
    LIB.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint, ctypes.c_int]
    LIB.getxattr.argtypes = LIB.setxattr.argtypes
    LIB.getxattr.restype = ctypes.c_ssize_t

def set_attribute(path, name, value):
    if MAC:
        buffer = ctypes.create_string_buffer(value)
        if LIB.setxattr(os.fsencode(path), name.encode(), buffer, len(value), 0, 0):
            raise OSError(ctypes.get_errno(), 'setxattr')
    else:
        os.setxattr(path, name, value)

def get_attribute(path, name):
    if not MAC: return os.getxattr(path, name)
    size = LIB.getxattr(os.fsencode(path), name.encode(), None, 0, 0, 0)
    if size < 0: raise OSError(ctypes.get_errno(), 'getxattr')
    buffer = ctypes.create_string_buffer(size)
    if LIB.getxattr(os.fsencode(path), name.encode(), buffer, size, 0, 0) != size:
        raise OSError(ctypes.get_errno(), 'getxattr')
    return buffer.raw[:size]

def run(*args, password=None, code=0):
    if DUAL and args[0] in ('create', 'create-selected') and '--encrypt' in args and '--encryption' not in args:
        args = (*args, '--encryption', 'dual')
    result = subprocess.run([BIN, *map(str, args)], input=None if password is None else password + '\n', capture_output=True, text=True)
    if result.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result

def contents(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest() for p in path.rglob('*') if p.is_file()}

def cleanup(path):
    if MAC: subprocess.run(['chmod', '-RN', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for root, dirs, files in os.walk(path):
        os.chmod(root, 0o700)
        for p in dirs: os.chmod(Path(root) / p, 0o700)
        for p in files:
            if not (Path(root) / p).is_symlink(): os.chmod(Path(root) / p, 0o600)
    shutil.rmtree(path)

class ProtectedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if DUAL and not json.loads(run('--capabilities').stdout)['aes256gcm']:
            raise unittest.SkipTest('AES hardware unavailable')
        cls.root = Path(tempfile.mkdtemp(prefix='rz-protected-'))
        cls.source = cls.root / 'source'; (cls.source / 'folder').mkdir(parents=True)
        cls.note = cls.source / 'folder' / 'private-name-82e452c0.txt'
        cls.note.write_bytes(b'private-content-27be20d17118\n' * 100)
        (cls.source / 'random.bin').write_bytes(random.Random(227).randbytes(5 * 1024 * 1024 + 71))
        (cls.source / 'empty').touch()
        os.chmod(cls.note, 0o640)
        set_attribute(cls.note, 'user.rz.binary', b'opaque\x00\xffvalue')
        os.utime(cls.note, ns=(1500000000111222333, 1600000000444555666))
        cls.modified = cls.note.stat().st_mtime_ns
        cls.archive = cls.root / 'encrypted.rz'
        run('create', cls.source, cls.archive, '--encrypt', '--password-stdin', '--volume-size', '1MiB', password=PASSWORD)
        cls.expected = contents(cls.source)

    @classmethod
    def tearDownClass(cls): cleanup(cls.root)

    def setUp(self): self.work = Path(tempfile.mkdtemp(dir=self.root))
    def tearDown(self): cleanup(self.work)

    def clone(self):
        dest = self.work / 'broken.rz'; shutil.copytree(self.archive, dest); return dest

    def extract(self, archive, output, password=PASSWORD):
        report = json.loads(run('extract', archive, output, '--json', '--password-stdin', password=password).stdout)
        self.assertEqual(report['warningCount'], 0)
        self.assertEqual(contents(output), self.expected)

    def test_encrypted_directory_and_metadata_roundtrip(self):
        locked = json.loads(run('list', self.archive, '--json').stdout)
        self.assertTrue(locked['encrypted'] and locked['locked'] and locked['preservesMetadata'])
        self.assertEqual(locked['entries'], [])
        self.assertEqual(locked['encryptionSuite'], 2 if DUAL else 1)
        unlocked = json.loads(run('list', self.archive, '--json', '--password-stdin', password=PASSWORD).stdout)
        self.assertFalse(unlocked['locked'])
        self.assertEqual(unlocked['encryptionSuite'], 2 if DUAL else 1)
        self.assertTrue(all(p.stat().st_size <= 1024 * 1024 for p in self.archive.glob('*.rz[vr]')))
        self.assertTrue(any('private-name' in e['path'] for e in unlocked['entries']))
        out = self.work / 'out'; self.extract(self.archive, out)
        note = out / 'folder' / self.note.name
        self.assertEqual(stat.S_IMODE(note.stat().st_mode), 0o640)
        self.assertEqual(note.stat().st_mtime_ns, self.modified)
        self.assertEqual(get_attribute(note, 'user.rz.binary'), b'opaque\x00\xffvalue')
        run('verify', self.archive, '--password-stdin', password=PASSWORD)

    def test_no_plaintext_names_or_contents_in_any_volume(self):
        for p in self.archive.iterdir():
            data = p.read_bytes()
            self.assertNotIn(b'private-name-82e452c0', data)
            self.assertNotIn(b'private-content-27be20d17118', data)
            self.assertNotIn(b'user.rz.binary', data)

    def test_wrong_password_and_no_password_do_not_publish(self):
        for index, password in enumerate(['incorrect', None]):
            output = self.work / f'bad-{index}'
            args = ['extract', self.archive, output]
            if password is not None: args += ['--password-stdin']
            run(*args, password=password, code=4)
            self.assertFalse(output.exists())
        run('verify', self.archive, '--password-stdin', password='incorrect', code=4)
        run('verify', self.archive)  # storage verification does not claim authentication
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_ciphertext_damage_repaired_without_password(self):
        broken = self.clone(); p = broken / 'd000000.rzv'
        with p.open('r+b') as f:
            head = f.read(HEADER); length = struct.unpack_from('<Q', head, 40)[0]
            f.seek(HEADER + length + 35); b = f.read(1); f.seek(-1, 1); f.write(bytes([b[0] ^ 0x55]))
        run('verify', broken, code=2)
        out = self.work / 'repaired'
        run('repair', broken, out)
        self.assertEqual(contents(out), contents(self.archive))
        self.extract(out, self.work / 'extracted')

    def test_missing_data_volume_keyless_repair(self):
        broken = self.clone(); (broken / 'd000000.rzv').unlink()
        run('verify', broken, code=2)
        run('repair', broken, self.work / 'fixed')
        self.extract(self.work / 'fixed', self.work / 'out')

    def test_private_index_corruption_never_lists_unverified_names(self):
        source = self.work / 'source'; source.mkdir(); (source / 'file').write_text('index corruption test')
        archive = self.work / 'plain'; run('create', source, archive)
        p = archive / 'd000000.rzv'
        with p.open('r+b') as f:
            head = f.read(HEADER); length = struct.unpack_from('<Q', head, 40)[0]
            f.seek(HEADER + length + 10); b = f.read(1); f.seek(-1, 1); f.write(bytes([b[0] ^ 1]))
        public = json.loads(run('list', archive, '--json').stdout)
        self.assertTrue(public['directoryUnavailable'])
        self.assertEqual(public['entries'], [])
        run('repair', archive, self.work / 'fixed')
        self.assertEqual(len(json.loads(run('list', self.work / 'fixed', '--json').stdout)['entries']), 1)

    def test_nonce_and_salt_randomize_repeated_archives(self):
        other = self.work / 'other'
        run('create', self.source, other, '--encrypt', '--password-stdin', '--volume-size', '1MiB', password=PASSWORD)
        self.assertNotEqual((other / 'manifest.rzm').read_bytes(), (self.archive / 'manifest.rzm').read_bytes())
        self.assertNotEqual((other / 'd000000.rzv').read_bytes(), (self.archive / 'd000000.rzv').read_bytes())

    def test_metadata_opt_out_and_restore_opt_out(self):
        archive = self.work / 'no-metadata'
        run('create', self.source, archive, '--no-metadata')
        self.assertFalse(json.loads(run('list', archive, '--json').stdout)['preservesMetadata'])
        run('extract', archive, self.work / 'plain-out')
        note = self.work / 'plain-out' / 'folder' / self.note.name
        self.assertEqual(stat.S_IMODE(note.stat().st_mode), 0o600)
        with self.assertRaises(OSError): get_attribute(note, 'user.rz.binary')
        run('extract', self.archive, self.work / 'skip-out', '--no-attributes', '--password-stdin', password=PASSWORD)
        self.assertEqual(stat.S_IMODE((self.work / 'skip-out' / 'folder' / self.note.name).stat().st_mode), 0o600)

    def test_read_only_directories_restored_last(self):
        source = self.work / 'readonly'; (source / 'folder').mkdir(parents=True)
        (source / 'folder' / 'executable').write_text('read-only metadata')
        os.chmod(source / 'folder' / 'executable', 0o751); os.chmod(source / 'folder', 0o555)
        run('create', source, self.work / 'archive')
        run('extract', self.work / 'archive', self.work / 'out')
        self.assertEqual(stat.S_IMODE((self.work / 'out' / 'folder').stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE((self.work / 'out' / 'folder' / 'executable').stat().st_mode), 0o751)

    def test_special_permissions_report_partial_metadata(self):
        source = self.work / 'special'; source.mkdir(); (source / 'file').write_text('special')
        os.chmod(source / 'file', 0o4755)
        run('create', source, self.work / 'archive')
        report = json.loads(run('extract', self.work / 'archive', self.work / 'out', '--json', code=5).stdout)
        self.assertGreater(report['warningCount'], 0)
        self.assertIn('Special permission', '\n'.join(report['metadataWarnings']))
        self.assertEqual(stat.S_IMODE((self.work / 'out' / 'file').stat().st_mode), 0o755)
        self.assertEqual((self.work / 'out' / 'file').read_text(), 'special')

    @unittest.skipUnless(MAC, 'macOS resource fork and FinderInfo')
    def test_large_resource_fork_and_finder_info(self):
        source = self.work / 'mac'; source.mkdir(); file = source / 'file'; file.write_text('data fork')
        fork = random.Random(31).randbytes(5 * 1024 * 1024 + 13)
        set_attribute(file, 'com.apple.ResourceFork', fork)
        finder = b'TEXTttxt' + bytes(24)
        set_attribute(file, 'com.apple.FinderInfo', finder)
        run('create', source, self.work / 'archive', '--encrypt', '--password-stdin', password=PASSWORD)
        run('extract', self.work / 'archive', self.work / 'out', '--password-stdin', password=PASSWORD)
        self.assertEqual(get_attribute(self.work / 'out' / 'file', 'com.apple.ResourceFork'), fork)
        self.assertEqual(get_attribute(self.work / 'out' / 'file', 'com.apple.FinderInfo'), finder)

    @unittest.skipUnless(MAC, 'macOS ACL')
    def test_macos_acl(self):
        source = self.work / 'acl'; source.mkdir(); file = source / 'file'; file.write_text('acl')
        subprocess.run(['chmod', '+a', 'everyone deny delete', str(file)], check=True)
        run('create', source, self.work / 'archive')
        run('extract', self.work / 'archive', self.work / 'out')
        acl = subprocess.check_output(['ls', '-le', str(self.work / 'out' / 'file')], text=True)
        self.assertIn('everyone deny delete', acl)

    @unittest.skipUnless(MAC, 'macOS inherited ACL isolation')
    def test_inherited_acl_isolation_and_restore(self):
        destination = self.work / 'shared'; destination.mkdir()
        rule = 'everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit'
        subprocess.run(['chmod', '+a', rule, str(destination)], check=True)
        source = self.work / 'source'; source.mkdir(); (source / 'file').write_text('private staging')
        archive = destination / 'archive'
        run('create', source, archive, '--encrypt', '--password-stdin', password=PASSWORD)
        self.assertNotIn('everyone', subprocess.check_output(['ls', '-lde', str(archive)], text=True))
        run('extract', archive, destination / 'out', '--password-stdin', password=PASSWORD)
        self.assertNotIn('everyone', subprocess.check_output(['ls', '-lde', str(destination / 'out')], text=True))
        self.assertNotIn('everyone', subprocess.check_output(['ls', '-le', str(destination / 'out' / 'file')], text=True))
        # Explicit/inherited ACLs belonging to source entries still survive.
        folder = source / 'folder'; folder.mkdir()
        subprocess.run(['chmod', '+a', rule, str(folder)], check=True)
        (folder / 'child').write_text('inherited')
        run('create', source, self.work / 'with-acl')
        run('extract', self.work / 'with-acl', self.work / 'acl-out')
        expected = subprocess.check_output(['ls', '-le', str(folder / 'child')], text=True).splitlines()[1:]
        actual = subprocess.check_output(['ls', '-le', str(self.work / 'acl-out' / 'folder' / 'child')], text=True).splitlines()[1:]
        self.assertEqual(expected, actual)

    def test_encrypted_empty_archive_is_still_locked(self):
        source = self.work / 'empty'; source.mkdir()
        archive = self.work / 'empty-rz'; run('create', source, archive, '--encrypt', '--password-stdin', password=PASSWORD)
        locked = json.loads(run('list', archive, '--json').stdout)
        self.assertTrue(locked['encrypted'] and locked['locked'])
        run('extract', archive, self.work / 'out', '--password-stdin', password=PASSWORD)
        self.assertEqual(list((self.work / 'out').iterdir()), [])

    def test_legacy_fixed_fixtures_remain_readable(self):
        for profile, filename in [(1, 'legacy.txt'), (2, 'legacy2.txt')]:
            archive = self.work / f'legacy-{profile}'; archive.mkdir()
            with tarfile.open(Path(__file__).parent / 'fixtures' / f'profile{profile}.tar.gz') as f:
                for member in f.getmembers():
                    self.assertTrue(member.isfile() and '/' not in member.name)
                    (archive / member.name).write_bytes(f.extractfile(member).read())
            run('verify', archive); run('extract', archive, self.work / f'out-{profile}')
            self.assertIn('compatibility fixture', (self.work / f'out-{profile}' / filename).read_text())

    def test_frozen_standard_encryption_fixture(self):
        archive = self.work / 'standard'; archive.mkdir()
        with tarfile.open(Path(__file__).parent / 'fixtures' / 'profile3-standard.tar.gz') as f:
            for member in f.getmembers():
                self.assertTrue(member.isfile() and '/' not in member.name)
                (archive / member.name).write_bytes(f.extractfile(member).read())
        run('verify', archive, '--password-stdin', password='fixture-password')
        run('extract', archive, self.work / 'standard-out', '--password-stdin', password='fixture-password')
        self.assertIn('compatibility fixture', (self.work / 'standard-out' / 'legacy3.txt').read_text())

    def test_invalid_encryption_options_and_password_limits(self):
        for args, data, code in [(['--encrypt'], None, 1), (['--encryption', 'dual'], None, 1),
                                (['--encrypt','--password-stdin','--encryption','unknown'], 'unused', 1), (['--password-stdin'], 'unused', 1),
                                (['--encrypt','--password-stdin'], '', 4),
                                (['--encrypt','--password-stdin'], 'a'*1025, 1),
                                (['--profile','2','--encrypt','--password-stdin'], 'unused', 1)]:
            run('create', self.source, self.work / 'bad', *args, password=data, code=code)
            self.assertFalse((self.work / 'bad').exists())

if __name__ == '__main__': unittest.main()
