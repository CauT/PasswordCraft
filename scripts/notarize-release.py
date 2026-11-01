#!/usr/bin/env python3
"""Submit once, retain the Apple job ID, then finish the same notarization job.

Credentials stay in a preconfigured macOS Keychain profile. This command never
accepts a password or API private key and never publishes to GitHub.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from signing import run, verify_signature


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_new(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def notary(profile, *args):
    result, _ = run('/usr/bin/xcrun', 'notarytool', *args,
                    '--keychain-profile', profile, '--output-format', 'json')
    return json.loads(result)


def submit(args):
    app, archive, state = args.app.resolve(), args.archive.resolve(), args.state.resolve()
    if state.exists():
        raise ValueError('Submission directory already exists; inspect its job instead of resubmitting')
    if state.is_relative_to(app):
        raise ValueError('Submission state must be outside the application')
    verify_signature(app, args.team_id)
    # Require an exact archive/app match before uploading anything.
    run(sys.executable, str(Path(__file__).with_name('verify-package.py')),
        str(archive), str(app), '--team-id', args.team_id)
    state.mkdir(parents=True, exist_ok=False)
    request = {'app': str(app), 'archive': str(archive), 'team_id': args.team_id,
               'archive_sha256': digest(archive),
               'executable_sha256': digest(app / 'Contents/MacOS/PasswordCraft')}
    write_new(state / 'request.json', request)
    # Store raw successful response before parsing so job ownership survives a
    # future schema change. A failed/interrupted upload is never auto-retried.
    response, _ = run('/usr/bin/xcrun', 'notarytool', 'submit', str(archive),
                      '--keychain-profile', args.profile, '--output-format', 'json')
    (state / 'submission.json').write_text(response)
    result = json.loads(response)
    print(json.dumps({'id': result['id'], 'state': str(state), 'status': 'submitted'}))


def finish(args):
    state, output = args.state.resolve(), args.output.resolve()
    request = json.loads((state / 'request.json').read_text())
    submission = json.loads((state / 'submission.json').read_text())
    job = submission['id']
    result = notary(args.profile, 'info', job)
    if result.get('id') != job:
        raise ValueError('Apple response does not match the retained submission ID')
    if result.get('status') != 'Accepted':
        print(json.dumps({'id': job, 'status': result.get('status'),
                          'action': 'Inspect this job; do not upload a duplicate'}))
        return 10
    log = notary(args.profile, 'log', job)
    (state / 'accepted-log.json').write_text(json.dumps(log, indent=2) + '\n')
    if (log.get('jobId') != job or log.get('status') != 'Accepted' or
            log.get('sha256') != request['archive_sha256']):
        raise ValueError('Notary log identity or accepted status mismatch')
    # Even warnings require review; do not silently publish them.
    if log.get('issues'):
        raise ValueError('Apple reported issues; inspect accepted-log.json before proceeding')
    app, archive = Path(request['app']), Path(request['archive'])
    if digest(archive) != request['archive_sha256'] or digest(app / 'Contents/MacOS/PasswordCraft') != request['executable_sha256']:
        raise ValueError('Submitted build changed while notarization was processing')
    if output.exists() or output.is_relative_to(app):
        raise ValueError('Final output must be a new directory outside the app')
    run(sys.executable, str(Path(__file__).with_name('verify-package.py')),
        str(archive), str(app), '--team-id', request['team_id'])
    output.mkdir(parents=True, exist_ok=False)
    final_app = output / app.name
    run('/usr/bin/ditto', str(app), str(final_app))
    run('/usr/bin/xcrun', 'stapler', 'staple', str(final_app))
    verify_signature(final_app, request['team_id'], notarized=True)
    final_archive = output / archive.name
    run('/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent',
        str(final_app), str(final_archive))
    verification, _ = run(sys.executable, str(Path(__file__).with_name('verify-package.py')),
                          str(final_archive), str(final_app), '--team-id', request['team_id'],
                          '--require-notarization')
    write_new(output / 'package-verification.json', json.loads(verification))
    (output / 'SHA256SUMS').write_text(digest(final_archive) + '  ' + final_archive.name + '\n')
    write_new(output / 'notarization-receipt.json', {
        'submission_id': job, 'status': 'Accepted', 'team_id': request['team_id'],
        'submitted_archive_sha256': request['archive_sha256'],
        'final_archive_sha256': digest(final_archive),
        'checks': ['Developer ID', 'hardened runtime', 'secure timestamp',
                   'stapled ticket', 'fresh extraction', 'Gatekeeper assessment']})
    print(json.dumps({'status': 'verified', 'archive': str(final_archive), 'id': job}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    start = commands.add_parser('submit')
    start.add_argument('--app', type=Path, required=True)
    start.add_argument('--archive', type=Path, required=True)
    start.add_argument('--team-id', required=True)
    start.add_argument('--state', type=Path, required=True)
    end = commands.add_parser('finish')
    end.add_argument('--state', type=Path, required=True)
    end.add_argument('--output', type=Path, required=True)
    for command in [start, end]:
        command.add_argument('--profile', required=True, help='Existing local notarytool Keychain profile')
    args = parser.parse_args()
    try:
        return submit(args) if args.action == 'submit' else finish(args)
    except (ValueError, OSError, RuntimeError, KeyError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'Notarization stopped: {error}\n')


if __name__ == '__main__':
    sys.exit(main())
