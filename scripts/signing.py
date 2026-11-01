"""Shared, fail-closed macOS distribution signature checks."""
import plistlib
import re
import subprocess


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f'{command[0]} failed ({result.returncode}): ' +
                           (result.stdout + result.stderr)[-4000:])
    return result.stdout, result.stderr


def verify_signature(app, team_id=None, notarized=False):
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    out, err = run('/usr/bin/codesign', '--display', '--verbose=4', str(app))
    description = out + err
    fields = {}
    for line in description.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            fields.setdefault(key, []).append(value)
    identity = {key: fields.get(key, []) for key in
                ['Authority', 'TeamIdentifier', 'Timestamp', 'CDHash', 'Identifier']}
    if team_id is not None:
        if not re.fullmatch(r'[A-Z0-9]{10}', team_id):
            raise ValueError('Expected a ten-character Apple Team ID')
        # Verify the Apple trust anchor and Developer ID Application certificate
        # OID, not just the human-readable certificate title.
        requirement = ('anchor apple generic and '
                       'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                       f'certificate leaf[subject.OU] = "{team_id}"')
        run('/usr/bin/codesign', '--verify', '--strict', '-R', requirement, str(app))
        if fields.get('TeamIdentifier') != [team_id] or not fields.get('Timestamp'):
            raise ValueError('Developer ID release requires the selected team and secure timestamp')
        code_directory = fields.get('CodeDirectory', [''])[0]
        if '(runtime)' not in code_directory:
            raise ValueError('Developer ID release requires hardened runtime')
        entitlements, _ = run('/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(app))
        values = plistlib.loads(entitlements.encode()) if entitlements.strip() else {}
        if values.get('com.apple.security.get-task-allow'):
            raise ValueError('Debug task access is forbidden in a release')
    if notarized:
        if team_id is None:
            raise ValueError('Notarized verification requires the expected Team ID')
        run('/usr/bin/xcrun', 'stapler', 'validate', str(app))
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', str(app))
    return identity
