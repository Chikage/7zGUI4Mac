#!/usr/bin/env python3
"""Parallel creation: format compatibility, progress, cancellation and failed writes."""
import hashlib
import json
import os
from pathlib import Path
import random
import resource
import selectors
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BIN = str(Path(sys.argv.pop(1)).resolve())
PASSWORD = 'parallel-archive-password'


def run(*args, password=None, code=0, **kwargs):
    result = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True,
                            input=None if password is None else password + '\n', timeout=60, **kwargs)
    if result.returncode != code:
        raise AssertionError(f'{args}: expected {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def contents(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def stored_stream(archive):
    manifest = (archive / 'manifest.rzm').read_bytes()
    size, blocks = struct.unpack_from('<QQ', manifest, 60)
    volumes = [p.read_bytes() for p in sorted(archive.glob('d*.rzv'))]
    output = bytearray()
    for block in range(blocks):
        volume = volumes[block % len(volumes)]
        index_size = struct.unpack_from('<Q', volume, 40)[0]
        offset = 120 + index_size + (block // len(volumes)) * 65536
        output.extend(volume[offset:offset + 65536])
    return bytes(output[:size])


class ThreadsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='rz-threads-'))
        cls.source = cls.root / 'source'
        (cls.source / 'empty-directory').mkdir(parents=True)
        (cls.source / 'a-large').write_bytes(random.Random(882).randbytes(13 * 1024 * 1024 + 53))
        (cls.source / 'empty').touch()
        for i in range(30): (cls.source / f'small-{i:02}').write_bytes(bytes([i]) * (100 + i))
        cls.expected = contents(cls.source)
        cls.aes = json.loads(run('--capabilities').stdout)['aes256gcm']

    @classmethod
    def tearDownClass(cls): shutil.rmtree(cls.root)

    def setUp(self): self.work = Path(tempfile.mkdtemp(dir=self.root))
    def tearDown(self): shutil.rmtree(self.work)

    def assert_clean(self, output):
        self.assertFalse(output.exists())
        self.assertFalse(list(self.work.glob('.rz-stage-*')))

    def test_roundtrip_and_serial_stream_identity(self):
        modes = [('profile2', ['--profile', '2'], None), ('plain3', ['--no-metadata'], None),
                 ('standard', ['--encrypt', '--password-stdin'], PASSWORD)]
        if self.aes: modes.append(('dual', ['--encrypt', '--password-stdin', '--encryption', 'dual'], PASSWORD))
        for name, options, password in modes:
            streams = []
            for count in (1, 4):
                with self.subTest(mode=name, threads=count):
                    archive = self.work / f'{name}-{count}.rz'
                    # Exercise the GUI's create-selected path too.
                    result = run('create-selected', archive, '--threads', count, '--progress',
                                 '--volume-size', '1MiB', *options, '--', *sorted(self.source.iterdir()), password=password)
                    stats = [line.split('\t') for line in result.stderr.splitlines() if line.startswith('RZPROGRESS1\t')]
                    self.assertTrue(stats)
                    self.assertTrue(all(len(row) == 8 for row in stats))
                    self.assertEqual(stats[-1][1], 'completed')
                    self.assertEqual(int(stats[-1][2]), sum(p.stat().st_size for p in self.source.iterdir() if p.is_file()))
                    self.assertEqual(int(stats[-1][4]), len(self.expected))
                    self.assertEqual([int(row[2]) for row in stats], sorted(int(row[2]) for row in stats))
                    unlock = ['--password-stdin'] if password else []
                    run('verify', archive, *unlock, password=password)
                    output = self.work / f'{name}-{count}-out'
                    run('extract', archive, output, '--no-attributes', *unlock, password=password)
                    self.assertEqual(contents(output), self.expected)
                    self.assertTrue((output / 'empty-directory').is_dir())
                    if password is None: streams.append(stored_stream(archive))
            if streams: self.assertEqual(*streams)

    def test_legacy_and_empty_auto(self):
        source = self.work / 'tiny'; source.mkdir()
        for profile in (1, 2, 3):
            archive = self.work / f'empty-{profile}'
            run('create', source, archive, '--profile', profile, '--threads', 'auto')
            run('verify', archive)
        (source / 'file').write_bytes(b'legacy parallel' * 100)
        archive = self.work / 'legacy'
        run('create', source, archive, '--profile', 1, '--threads', 4)
        output = self.work / 'legacy-out'; run('extract', archive, output)
        self.assertEqual(contents(source), contents(output))

    def test_invalid_thread_options(self):
        for value in ('0', '-1', '65', '1.0', 'fast', '', '9999999999999999999999999'):
            output = self.work / 'invalid'
            run('create', self.source, output, '--threads', value, code=1)
            self.assert_clean(output)
        run('create', self.source, self.work / 'duplicate', '--threads', 2, '--threads', 4, code=1)

    def test_write_failure_cleans_workers_and_staging(self):
        def limit_output():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))
        output = self.work / 'failed.rz'
        result = run('create', self.source, output, '--threads', 4, '--encrypt', '--password-stdin',
                     password=PASSWORD, code=1, preexec_fn=limit_output)
        self.assertIn('Write failed', result.stderr)
        self.assert_clean(output)

    def test_signals_during_parallel_compression(self):
        source = self.work / 'large-source'; source.mkdir()
        with (source / 'sparse').open('wb') as file: file.truncate(1024 * 1024 * 1024)
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                output = self.work / f'cancel-{sig}.rz'
                process = subprocess.Popen([BIN, 'create', str(source), str(output), '--threads', '4', '--progress',
                                            '--encrypt', '--password-stdin'], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    process.stdin.write(PASSWORD + '\n'); process.stdin.close(); process.stdin = None
                    active = False
                    with selectors.DefaultSelector() as selector:
                        selector.register(process.stderr, selectors.EVENT_READ)
                        deadline = time.monotonic() + 20
                        while time.monotonic() < deadline and process.poll() is None:
                            if not selector.select(timeout=0.1): continue
                            fields = process.stderr.readline().strip().split('\t')
                            if len(fields) == 8 and fields[1] == 'compressing' and int(fields[2]) > 0:
                                active = True; break
                    self.assertTrue(active, 'must cancel after workers have committed frames')
                    process.send_signal(sig)
                    _, error = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 1)
                    self.assertIn('cancelled', error)
                    self.assert_clean(output)
                finally:
                    if process.poll() is None: process.kill(); process.communicate()


if __name__ == '__main__': unittest.main()
