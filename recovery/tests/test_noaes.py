#!/usr/bin/env python3
"""No AES hardware: fail closed for crypto, retain storage verification/repair."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary, no_aes = sys.argv[1:]
def run(exe, *args, password=None, code=0):
    p = subprocess.run([exe, *map(str, args)], input=None if password is None else password + '\n', text=True, capture_output=True)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p
def hashes(path):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in path.iterdir()}

assert json.loads(run(no_aes, '--capabilities').stdout)['aes256gcm'] is False
with tempfile.TemporaryDirectory(prefix='rz-noaes-') as tmp:
    root = Path(tmp); source = root / 'source'; source.mkdir(); (source / 'secret').write_text('no AES fallback test')
    rejected = run(no_aes, 'create', source, root / 'rejected', '--encrypt', '--encryption', 'dual', '--password-stdin', password='test', code=1)
    assert 'AES-256-GCM is unavailable' in rejected.stderr
    assert not (root / 'rejected').exists()
    run(no_aes, 'create', source, root / 'standard', '--encrypt', '--password-stdin', password='test')
    run(no_aes, 'verify', root / 'standard', '--password-stdin', password='test')
    if json.loads(run(binary, '--capabilities').stdout)['aes256gcm']:
        archive = root / 'dual'
        run(binary, 'create', source, archive, '--encrypt', '--encryption', 'dual', '--password-stdin', password='test')
        original = hashes(archive)
        assert json.loads(run(no_aes, 'list', archive, '--json').stdout)['locked'] is True
        run(no_aes, 'verify', archive)
        for command in ['list', 'verify', 'extract']:
            args = [command, archive] + ([root / 'out'] if command == 'extract' else []) + ['--password-stdin']
            rejected = run(no_aes, *args, password='test', code=1)
            assert 'AES-256-GCM is unavailable' in rejected.stderr
        assert not (root / 'out').exists()
        (archive / 'd000000.rzv').unlink()
        run(no_aes, 'repair', archive, root / 'fixed')
        assert hashes(root / 'fixed') == original
        run(binary, 'verify', root / 'fixed', '--password-stdin', password='test')
    assert not list(root.glob('.rz-stage-*'))
print('Unsupported AES fails closed; standard encryption and keyless repair remain available')
