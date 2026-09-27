#!/usr/bin/env python3
"""Generated recovery keys, auto discovery, pairing, failures and keyless repair."""
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
import tempfile
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
def run(*args, code=0):
    p = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p
def hashes(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest() for p in path.rglob('*') if p.is_file()}

class KeyFileTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='rz-key-file-'))
        self.source = self.root / 'input'; self.source.mkdir()
        (self.source / 'private.txt').write_text('recovery key protected content')
        (self.source / 'random.bin').write_bytes(random.Random(67).randbytes(5 * 1024 * 1024))
        os.chmod(self.source / 'private.txt', 0o640)
        self.archive = self.root / 'archive.rz'; self.key = self.root / 'archive.rzkey'
        self.suite = 'dual' if json.loads(run('--capabilities').stdout)['aes256gcm'] else 'standard'

    def tearDown(self): shutil.rmtree(self.root)
    def create(self, archive=None, suite=None):
        return run('create', self.source, archive or self.archive, '--generate-key-file', '--encryption', suite or self.suite,
                   '--volume-size', '1MiB', '--recovery-percent', '30')
    def listing(self, archive=None, *args): return json.loads(run('list', archive or self.archive, '--json', *args).stdout)

    def test_generated_key_and_automatic_unlock(self):
        result = self.create()
        self.assertEqual(self.key.stat().st_size, 88)
        self.assertEqual(stat.S_IMODE(self.key.stat().st_mode), 0o600)
        key_data = self.key.read_bytes()
        self.assertNotIn(key_data[24:56].hex(), result.stdout + result.stderr)
        self.assertFalse(list(self.archive.glob('*.rzkey')))
        self.assertTrue(self.listing()['requiresKeyFile'])
        self.assertFalse(self.listing()['locked'])
        self.assertTrue(self.listing(None, '--no-auto-key-file')['locked'])
        run('verify', self.archive, '--auto-key-file')
        run('extract', self.archive, self.root / 'out')
        self.assertEqual(hashes(self.source), hashes(self.root / 'out'))
        self.assertEqual(stat.S_IMODE((self.root / 'out/private.txt').stat().st_mode), 0o640)
        self.assertTrue(all(p.stat().st_size <= 1024 * 1024 for p in self.archive.iterdir()))

    def test_missing_key_prompts_and_manual_key_works(self):
        self.create(); backup = self.root / 'separate'; backup.mkdir(); moved = backup / 'renamed.backup'
        self.key.rename(moved)
        self.assertTrue(self.listing()['locked'])
        run('extract', self.archive, self.root / 'missing', code=6)
        run('verify', self.archive, '--auto-key-file', code=6)
        self.assertFalse((self.root / 'missing').exists())
        run('extract', self.archive, self.root / 'manual', '--key-file', moved)
        self.assertEqual(hashes(self.source), hashes(self.root / 'manual'))
        self.assertFalse(self.listing(None, '--key-file', moved)['locked'])

    def test_identity_matching_survives_renames_and_ignores_other_keys(self):
        self.create(); self.create(self.root / 'other.rz')
        self.key.rename(self.root / 'unrelated-name.rzkey')
        moved = self.root / 'renamed.rz'; self.archive.rename(moved)
        self.assertFalse(self.listing(moved)['locked'])
        run('extract', moved, self.root / 'wrong', '--key-file', self.root / 'other.rzkey', code=6)
        self.assertFalse((self.root / 'wrong').exists())
        run('extract', str(moved) + '/', self.root / 'out')

    def test_invalid_truncated_and_symlink_keys(self):
        self.create(); original = self.key.read_bytes()
        for value in [b'', original[:50], original + b'x', original[:30] + bytes([original[30] ^ 1]) + original[31:]]:
            self.key.write_bytes(value)
            self.assertTrue(self.listing()['locked'])
            run('extract', self.archive, self.root / 'out', '--key-file', self.key, code=6)
            self.assertFalse((self.root / 'out').exists())
        self.key.unlink(); elsewhere = self.root / 'backup'; elsewhere.mkdir()
        target = elsewhere / 'key'; target.write_bytes(original); self.key.symlink_to(target)
        self.assertTrue(self.listing()['locked'])
        run('list', self.archive, '--key-file', self.key, code=6)

    def test_keyless_repair_then_auto_unlock_with_original_key(self):
        self.create(); expected = hashes(self.archive)
        backup = self.root / 'backup'; backup.mkdir(); self.key.rename(backup / 'key')
        p = self.archive / 'd000000.rzv'
        with p.open('r+b') as f:
            n = struct.unpack_from('<Q', f.read(120), 40)[0]
            f.seek(120 + n + 37); b = f.read(1); f.seek(-1, 1); f.write(bytes([b[0] ^ 55]))
        repaired = self.root / 'fixed.rz'; run('repair', self.archive, repaired)
        self.assertEqual(hashes(repaired), expected)
        self.assertTrue(self.listing(repaired)['locked'])
        (backup / 'key').rename(self.key)
        run('extract', repaired, self.root / 'out')
        self.assertEqual(hashes(self.source), hashes(self.root / 'out'))

    def test_existing_key_or_symlink_never_overwritten(self):
        for symlink in [False, True]:
            if symlink: self.key.symlink_to(self.root / 'nonexistent')
            else: self.key.write_bytes(b'original key')
            p = subprocess.run([BIN, 'create', str(self.source), str(self.archive), '--generate-key-file', '--encryption', self.suite], capture_output=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertFalse(self.archive.exists())
            if symlink: self.assertTrue(self.key.is_symlink())
            else: self.assertEqual(self.key.read_bytes(), b'original key')
            self.key.unlink()
        self.assertFalse(list(self.root.glob('.rz-stage-*')))

    def test_late_conflicts_rollback_only_own_outputs(self):
        (self.source / 'random.bin').write_bytes(random.Random(75).randbytes(24 * 1024 * 1024))
        for conflict in ['archive', 'key']:
            p = subprocess.Popen([BIN, 'create', str(self.source), str(self.archive), '--generate-key-file', '--encryption', self.suite, '--progress'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertIn(b'RZPROGRESS1', p.stderr.readline())
            if conflict == 'archive': self.archive.mkdir(); (self.archive / 'sentinel').write_bytes(b'keep')
            else: self.key.write_bytes(b'keep')
            p.communicate(timeout=30)
            self.assertNotEqual(p.returncode, 0)
            if conflict == 'archive':
                self.assertEqual((self.archive / 'sentinel').read_bytes(), b'keep'); self.assertFalse(self.key.exists()); shutil.rmtree(self.archive)
            else:
                self.assertEqual(self.key.read_bytes(), b'keep'); self.assertFalse(self.archive.exists()); self.key.unlink()
            self.assertFalse(list(self.root.glob('.rz-stage-*')))

    def test_cancel_does_not_publish_archive_or_key(self):
        (self.source / 'random.bin').write_bytes(random.Random(79).randbytes(24 * 1024 * 1024))
        p = subprocess.Popen([BIN, 'create', str(self.source), str(self.archive), '--generate-key-file', '--encryption', self.suite, '--progress'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertIn(b'RZPROGRESS1', p.stderr.readline()); p.send_signal(signal.SIGINT); p.communicate(timeout=30)
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(self.archive.exists()); self.assertFalse(self.key.exists())
        self.assertFalse(list(self.root.glob('.rz-stage-*')))

    def test_standard_key_file_and_fresh_secrets(self):
        self.create(suite='standard'); self.create(self.root / 'other.rz', suite='standard')
        self.assertNotEqual(self.key.read_bytes()[24:56], (self.root / 'other.rzkey').read_bytes()[24:56])
        self.assertEqual(self.listing()['encryptionSuite'], 1)
        run('extract', self.archive, self.root / 'out')

    def test_auto_unlock_keeps_repair_entry_when_private_index_is_missing(self):
        (self.source / 'random.bin').unlink(); self.create()
        (self.archive / 'd000000.rzv').unlink()
        listing = self.listing()
        self.assertTrue(listing['directoryUnavailable'] and listing['locked'])
        self.assertEqual(listing['entries'], [])
        repaired = self.root / 'fixed.rz'; run('repair', self.archive, repaired)
        self.assertFalse(self.listing(repaired)['locked'])

if __name__ == '__main__': unittest.main()
