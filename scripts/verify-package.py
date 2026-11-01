#!/usr/bin/env python3
"""Verify a distribution archive; optionally retain its fresh extraction for UI acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
parser.add_argument('app', type=Path)
parser.add_argument('--extract-to', type=Path, help='A new directory to retain the verified extraction')
args = parser.parse_args()
archive, app = args.archive.resolve(), args.app.resolve()
with zipfile.ZipFile(archive) as package:
    members = package.namelist()
    assert members and len(members) == len(set(members)), 'Empty or duplicate archive members'
    for entry in package.infolist():
        name = entry.filename
        assert not name.startswith('/') and '..' not in Path(name).parts and '\\' not in name
        assert Path(name).parts[0] == app.name, 'Unexpected archive root'
        assert '__MACOSX' not in Path(name).parts and not Path(name).name.startswith('._')
        if stat.S_ISLNK(entry.external_attr >> 16):
            target = package.read(entry).decode('utf-8')
            resolved = os.path.normpath(str(Path(name).parent / target))
            assert not os.path.isabs(target) and resolved.startswith(app.name + '/'), 'Escaping symlink'


def manifest(base):
    result = {}
    for path in [base] + sorted(base.rglob('*')):
        info = path.lstat()
        key = str(path.relative_to(base))
        if path.is_symlink():
            value = {'symlink': os.readlink(path)}
        elif path.is_file():
            value = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        elif path.is_dir():
            value = {'directory': True}
        else:
            raise ValueError('Unsupported file type in application: ' + key)
        value['mode'] = stat.S_IMODE(info.st_mode)
        result[key] = value
    return result


def verify(destination):
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(destination)], check=True)
    extracted = destination / app.name
    assert manifest(app) == manifest(extracted), 'Archive differs from build bytes/modes/symlinks'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(extracted)], check=True)
    executable = extracted / 'Contents/MacOS/PasswordCraft'
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).strip()
    assert architectures == 'arm64', 'Archive architecture does not match its arm64 label'
    with (extracted / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    assert info['CFBundleIdentifier'] == 'io.github.CauT.PasswordCraft', 'Unexpected bundle identity'
    for key in ['CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable']:
        assert info[key] == 'PasswordCraft', 'Unexpected product name: ' + key
    return {'bundle_id': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'architecture': architectures}


if args.extract_to:
    destination = args.extract_to.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    identity = verify(destination)
else:
    with tempfile.TemporaryDirectory(prefix='passwordcraft-package-') as temporary:
        identity = verify(Path(temporary))

print(json.dumps({'archive': str(archive), 'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                  'executable_sha256': hashlib.sha256((app / 'Contents/MacOS/PasswordCraft').read_bytes()).hexdigest(),
                  'identity': identity, 'retained_extraction': str(args.extract_to.resolve()) if args.extract_to else None,
                  'status': 'PASS', 'checks': ['safe archive entries', 'no AppleDouble', 'fresh extraction',
                  'byte/mode/symlink equality', 'strict deep ad-hoc signature', 'arm64 binary']}, indent=2))
