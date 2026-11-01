# PasswordCraft compatibility

PasswordCraft is the new name of the independently implemented LocalVault application. It does not contain 1Password application code or assets and is not affiliated with 1Password.

## Existing files

The product, Swift executable target, application entry point, window, menus and distribution archive are named PasswordCraft. Its bundle identifier is `io.github.CauT.PasswordCraft`.

Encryption is deliberately unchanged. Existing `.localvault` files, the authenticated `LocalVault` format prefix, `LocalVault-Transfer` JSON schema, `localvault_json` CSV column and `localvaultID` interchange fields retain their original identifiers. Replacing these strings as branding would invalidate existing encrypted files or lose migration identity. They describe persistent formats, not another application users need to install.

Backups remain in `~/Library/Application Support/LocalVault/Backups/` so existing recovery points stay discoverable. The private `LocalVault-WriteLocks-v1` temporary lock namespace also remains shared with the previous version. No files or backups are moved or deleted during the rename. Quit the old application before editing the same vault with PasswordCraft.

The new bundle uses its own preferences and biometric Keychain service. Open existing vaults explicitly on first launch; recent-file lists are not copied automatically. Existing master passwords still work. Touch ID must be enabled again on compatible hardware; no existing Keychain records are silently moved or deleted. Positive Touch ID authentication has not been hardware-tested.

## Interface language

English is the default, independently of the macOS language. English and Simplified Chinese can be selected from the main window or Language menu, including while editing. The preference is local to the app and persists across launches. Changing language does not reset open drafts or change vault bytes.

Built-in category identifiers remain stable; their display labels are localized. Existing and imported item titles, tags, notes, field labels, and source snapshots are user data and remain unchanged. Newly added template fields use the selected language; adding the same template after switching languages recognizes existing standard labels instead of duplicating them. System-owned messages may follow the macOS language.

## Import coverage

Imports are read-only against the source and previewed before saving into the selected encrypted destination. Preserve your source and compare counts, fields and attachments. No user's real vault is bundled or used in tests.

| Format | Supported scope and limits |
| --- | --- |
| OPVault | `default` profile; authenticated keys, records and supported v1/v2 attachments; OTP, password history, trash and source metadata. Folders become tags; smart rules are preserved as notes, not executed. |
| AgileKeychain | `data/default`, `encryptionKeys.js`, SL5/SL3 and validated encrypted attachment-definition layouts. This legacy format lacks authenticated item encryption; CRC is not authentication. Unknown layouts fail rather than silently omitting files. |
| 1PIF | File or export directory; supported Mac/Windows records and `attachments/<owner>/…`. Select the complete directory to import attachments. A single-file export cannot preserve attachments or all native revision history. |
| 1PUX | Version 3 ZIP32 stored/deflate, documents and section-file references. Multiple source vaults merge into the selected destination while retaining source identity. ZIP64, encrypted ZIP and unknown extra/icon files are rejected. |
| JSON / CSV | Full transfer JSON v2 (v1 readable), or rich CSV with the authoritative `localvault_json` column, preserves fields, revisions and attachments. Generic CSV only preserves information its columns contain. Exports are plaintext and require confirmation. |

Individual attachments are limited to 16 MiB; serialized vault content, including history and attachments, to 32 MiB. 1PUX input archives are limited to 64 MiB with separate decompression limits. Missing source inventory cannot prove that records or attachments were never removed before import.

## Verification scope

The self-contained `VaultCoreChecks` executable uses synthetic fixtures and fixed cryptographic vectors. It checks encryption, tamper rejection, old-format upgrade, backups, rekeying, imports, attachments, TOTP, resource limits, multi-vault lifecycle, recoverable transfers and real concurrent writers. Test passwords are synthetic and intentionally public.

Optional independent public reference packages are not vendored. Tests explicitly print `UNVERIFIED` when their environment variables are absent:

- `PASSWORDCRAFT_OPVAULT_REFERENCE_ROOT`: KeePassXC's OPVault test package.
- `PASSWORDCRAFT_AGILE_REFERENCE_ROOT`: the 1pass test AgileKeychain.
- `PASSWORDCRAFT_AGILE_LEGACY_REFERENCE_ROOT`: the gwik legacy AgileKeychain test package.
- `PASSWORDCRAFT_LEGACY_FILES_REFERENCE_ROOT`: the OnePIF public sample vault directory.

Passing fixture checks is not an independent security audit, real-user migration, Touch ID hardware test, or proof of compatibility with every historical format variant.
