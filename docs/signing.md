# Developer ID signing and notarization

The existing 0.4.0 release is ad-hoc signed. A signed release is only verified
after the steps below succeed against its actual final archive. Never replace
an existing release asset with a different file under the same version.

## Local prerequisites

Use an active Apple Developer Program team, a Developer ID Application
certificate with its corresponding private key in the macOS Keychain, and a
validated `notarytool` Keychain profile. Store credentials outside the checkout;
do not commit passwords, private keys, certificates with private keys, browser
sessions, or credential files. Application passwords should be entered through
the tool's secure prompt, not command-line arguments or shell history.

```sh
xcrun notarytool store-credentials PasswordCraft-notary \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

The command prompts for the app-specific password. Alternatively provision a
Keychain profile with an App Store Connect API key using Apple's documented
workflow. Account agreements and authentication remain the account holder's
responsibility.

## Build and submit once

```sh
export PASSWORDCRAFT_SIGNING_IDENTITY='YOUR_DEVELOPER_ID_CERTIFICATE_FINGERPRINT'
export PASSWORDCRAFT_TEAM_ID='YOUR_TEAM_ID'
./scripts/package.sh "$PWD/outputs/signed-build"
/usr/bin/python3 scripts/notarize-release.py submit \
  --app "$PWD/outputs/signed-build/PasswordCraft.app" \
  --archive "$PWD/outputs/signed-build/PasswordCraft-0.4.1-mac-arm64.zip" \
  --team-id "$PASSWORDCRAFT_TEAM_ID" --profile PasswordCraft-notary \
  --state "$PWD/outputs/notary-job"
```

Without a signing identity, `package.sh` creates a development ad-hoc build.
That output is not a notarized release. Supplying an identity requires an
explicit expected team and verifies the Apple Developer ID certificate
requirement, hardened runtime and secure timestamp.

The submission directory retains the original archive digest and Apple's job
ID. If upload observation is interrupted, inspect `notarytool history` before
retrying; do not infer that Apple stopped processing or automatically resubmit.

## Finish the retained job

```sh
/usr/bin/python3 scripts/notarize-release.py finish \
  --state "$PWD/outputs/notary-job" --profile PasswordCraft-notary \
  --output "$PWD/outputs/notarized-release"
```

This polls the existing job once. Exit code 10 means it is not accepted yet;
inspect the reported status, wait if in progress, and reuse the same job. It
checks the accepted log against the submitted archive digest, refuses reported
issues, verifies unchanged input, copies the app, staples the ticket and creates
a new ZIP. The original submission and earlier builds remain intact.

The final archive is freshly extracted and checked for byte/mode/symlink
equality, Developer ID team, hardened runtime, timestamp, stapled ticket and
Gatekeeper acceptance. Only then are verification and notarization receipts
written. These checks do not replace an actual downloaded-app launch or an
independent security audit. Test the final downloaded artifact and publish its
ZIP with `SHA256SUMS`; build receipts contain local paths and should stay local.

[Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
