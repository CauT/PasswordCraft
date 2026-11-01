# PasswordCraft 0.4.1

This release adds an English-by-default interface with a persistent English / Simplified Chinese selector, Developer ID signing, and Apple notarization. Language switching preserves open drafts and stored data. The application is local-only, requires no account or subscription, and includes direct legacy-vault import, encrypted attachments and history, offline TOTP, batch management, multiple vaults and local password checks.

The application target, executable, app bundle, visible branding, quick-access window and package filenames use PasswordCraft. Persistent vault and interchange identifiers remain compatible; see [compatibility](compatibility.md).

## Install and build

Download the Apple silicon archive from [Releases](https://github.com/CauT/PasswordCraft/releases), extract it and open `PasswordCraft.app`. Quit earlier versions before opening the same vault. Keep an independent backup of important passwords.

The build declares macOS 13 or later; actual local acceptance is on macOS 26.2 / Apple silicon. Version 0.4.1 is Developer ID signed with hardened runtime and a secure timestamp. Apple accepted submission `237f1a32-ddc8-48a8-bb2c-d6a90da57909`; its ticket is stapled to the application. Fresh archive extraction preserves the bundle bytes, modes and symlinks, and passes strict deep signature, stapler and Gatekeeper assessment. This is a distribution check, not an independent security audit. Version 0.4.0 remains an earlier ad-hoc development release.

Build with Swift 6.2 and Apple's command-line tools. The app has no third-party package dependencies. Run the commands in the [README](../README.md). Packaging writes a new directory, retains earlier packages, and emits local build/integrity receipts. Receipts may contain machine paths and are not release assets.

## Current limitations

- Touch ID has a tested unavailable-device fallback; positive authentication and fingerprint-set invalidation still need real hardware verification.
- Application-menu quick access is verified. System-wide hotkey activation, menu-bar activation and conflicts still need interactive verification.
- Automatic idle locking is implemented; real system sleep/lock-screen journeys have not been exercised.
- No browser autofill, passkeys, cloud accounts, multi-device merge, breach service, team sharing or automatic updates.
- No independent security audit, Intel build or other-macOS acceptance. Plaintext exports and explicitly exported attachments must be handled accordingly.

The MIT license is inherited from the source project; its copyright notice is preserved in [LICENSE](../LICENSE). Bundled test fixtures are synthetic. Third-party applications, private vaults, local acceptance recordings and external reference datasets are excluded from the source release.

## Build provenance

Application source: `44735bceeb21286cb8d53c7e97c742e226e943fd` (0.4.1, build 5). Release documentation is updated after notarization; the accepted application was not rebuilt. The release includes `SHA256SUMS` and a public notarization receipt. Signing credentials and local build reports are not published.
