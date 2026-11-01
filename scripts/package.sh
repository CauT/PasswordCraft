#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
VERSION=0.4.1
BUILD=5
IDENTITY="${PASSWORDCRAFT_SIGNING_IDENTITY:--}"
TEAM="${PASSWORDCRAFT_TEAM_ID:-}"
if [ "$IDENTITY" != "-" ] && [ -z "$TEAM" ]; then
  echo "Developer ID packaging requires PASSWORDCRAFT_TEAM_ID" >&2
  exit 1
fi
OUTPUT="${1:-$PWD/outputs/packages/$VERSION-$(date -u +%Y%m%dT%H%M%SZ)}"
if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite an existing package directory: $OUTPUT" >&2
  exit 1
fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
swift build -c release --disable-sandbox --product PasswordCraft
APP="$OUTPUT/PasswordCraft.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PasswordCraft "$APP/Contents/MacOS/PasswordCraft"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.CauT.PasswordCraft</string>
<key>CFBundleName</key><string>PasswordCraft</string>
<key>CFBundleDisplayName</key><string>PasswordCraft</string>
<key>CFBundleExecutable</key><string>PasswordCraft</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Independent local password manager. Not affiliated with 1Password.</string>
</dict></plist>
PLIST
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --options runtime "$APP"
else
  codesign --force --sign "$IDENTITY" --timestamp --options runtime "$APP"
fi
codesign --verify --strict --deep "$APP"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUTPUT/PasswordCraft-$VERSION-mac-arm64.zip"
if [ "$IDENTITY" = "-" ]; then
  /usr/bin/python3 scripts/verify-package.py "$OUTPUT/PasswordCraft-$VERSION-mac-arm64.zip" "$APP" > "$OUTPUT/package-verification.json"
else
  /usr/bin/python3 scripts/verify-package.py "$OUTPUT/PasswordCraft-$VERSION-mac-arm64.zip" "$APP" --team-id "$TEAM" > "$OUTPUT/package-verification.json"
fi
/usr/bin/python3 - "$OUTPUT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path.cwd()
out = pathlib.Path(sys.argv[1])
source = {}
for base in [root / 'Sources', root / 'scripts']:
    for path in sorted(base.rglob('*')):
        if path.is_file() and path.suffix in {'.swift', '.sh', '.py'}:
            source[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
source['Package.swift'] = hashlib.sha256((root / 'Package.swift').read_bytes()).hexdigest()
receipt = {
    'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'source_status': subprocess.check_output(['git', 'status', '--porcelain', '--', 'Sources', 'Package.swift', 'scripts'], text=True).splitlines(),
    'source_files_sha256': source,
    'package': json.loads((out / 'package-verification.json').read_text()),
    'scope': 'Build and signature checks only. Notarization and final distribution require notarize-release.py.'
}
(out / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
echo "$APP"
