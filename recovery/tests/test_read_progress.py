#!/usr/bin/env python3
"""Read telemetry is opt-in, accurate, and separate from JSON reports."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())


def run(*args, password=None):
    return subprocess.run([BIN, *map(str, args)], input=password, text=True,
                          capture_output=True, timeout=60)


def records(result):
    rows = [line.split('\t') for line in result.stderr.splitlines()
            if line.startswith('RZREADPROGRESS1\t')]
    for row in rows:
        assert len(row) == 7, row
        values = list(map(int, row[2:]))
        assert all(v >= 0 for v in values), row
        assert values[0] <= values[1] and values[2] <= values[3], row
    return rows


class ReadProgressTests(unittest.TestCase):
    def test_all_profiles_and_encrypted_reads(self):
        for profile, encrypted in [(1, False), (2, False), (3, False), (4, False),
                                   (5, False), (3, True), (4, True), (5, True)]:
            with self.subTest(profile=profile, encrypted=encrypted), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root / 'source'
                source.mkdir()
                data = b'read progress\n' * 750_000
                (source / 'content.bin').write_bytes(data)
                (source / 'empty').touch()
                (source / 'folder').mkdir()
                archive = root / 'archive'
                options = ['--profile', profile, '--no-metadata']
                if profile >= 4:
                    options += ['--data-volumes', 2, '--recovery-volumes', 1]
                if encrypted:
                    options += ['--encrypt', '--password-stdin']
                password = 'private-progress-password\n' if encrypted else None
                created = run('create', source, archive, *options, password=password)
                self.assertEqual(created.returncode, 0, created.stderr)
                self.assertNotIn('RZREADPROGRESS1', created.stderr)
                credentials = ['--password-stdin'] if encrypted else []
                for command in ('verify', 'extract'):
                    args = [command, archive]
                    if command == 'extract':
                        args += [root / 'out', '--json']
                    result = run(*args, '--progress', *credentials, password=password)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    rows = records(result)
                    self.assertEqual(rows[0][1], 'preparing')
                    self.assertEqual(rows[-1][1], 'completed')
                    self.assertEqual(rows[-1][2], rows[-1][3])
                    self.assertNotIn('private-progress-password', result.stderr)
                    self.assertNotIn('content.bin', result.stderr)
                    if command == 'extract' or profile >= 3:
                        self.assertEqual(int(rows[-1][3]), len(data))
                        self.assertEqual(rows[-1][4:6], ['2', '2'])
                        self.assertTrue(any(0 < int(r[2]) < int(r[3])
                                            for r in rows if r[1] in ('extracting', 'checking')))
                    if command == 'extract':
                        self.assertTrue(json.loads(result.stdout)['outputPublished'])
                        self.assertEqual((root / 'out/content.bin').read_bytes(), data)
                    self.assertNotIn('RZREADPROGRESS1', result.stdout)
                silent = run('verify', archive, *credentials, password=password)
                self.assertEqual(silent.returncode, 0, silent.stderr)
                self.assertEqual(records(silent), [])
                if encrypted:
                    # Without a credential, verification remains a storage-only operation.
                    storage = run('verify', archive, '--progress')
                    self.assertEqual(storage.returncode, 0, storage.stderr)
                    self.assertFalse(any(r[1] == 'checking' for r in records(storage)))
                    self.assertEqual(records(storage)[-1][4:6], ['0', '0'])
                    wrong = run('extract', archive, root / 'bad', '--json', '--progress',
                                '--password-stdin', password='wrong\n')
                    self.assertEqual(wrong.returncode, 4)
                    self.assertFalse(any(r[1] == 'completed' for r in records(wrong)))
                    self.assertFalse((root / 'bad').exists())

    def test_damaged_archive_never_reports_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'source'
            source.mkdir()
            (source / 'file').write_bytes(b'x' * 100_000)
            archive = root / 'archive'
            result = run('create', source, archive, '--profile', 5,
                         '--data-volumes', 2, '--recovery-volumes', 1)
            self.assertEqual(result.returncode, 0, result.stderr)
            next(archive.glob('*.rzv')).unlink()
            damaged = run('verify', archive, '--progress')
            self.assertEqual(damaged.returncode, 2, damaged.stderr)
            self.assertTrue(records(damaged))
            self.assertFalse(any(r[1] == 'completed' for r in records(damaged)))


if __name__ == '__main__':
    unittest.main()
