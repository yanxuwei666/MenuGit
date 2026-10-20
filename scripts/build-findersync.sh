#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/extensions/macos/FinderSyncExtension.swift"
INFO="$ROOT/extensions/macos/Info.plist"
ENTITLEMENTS="$ROOT/extensions/macos/MenuGitFinderSync.entitlements"
APP="$ROOT/extensions/macos/build/MenuGitFinderSync.appex"
CONTENTS="$APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/MenuGitFinderSync"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
cp "$INFO" "$CONTENTS/Info.plist"
printf 'XPC!????' > "$CONTENTS/PkgInfo"

xcrun swiftc \
  -module-name MenuGitFinderSync \
  -parse-as-library \
  -emit-executable \
  -application-extension \
  -target "$(uname -m)-apple-macosx12.0" \
  -sdk "$(xcrun --show-sdk-path)" \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework Cocoa \
  -framework FinderSync \
  -o "$EXECUTABLE" \
  "$SOURCE" "$ROOT/extensions/macos/MenuGitFinderMenu.swift"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$APPLE_SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" --options runtime --timestamp "$APP"
else
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
fi

plutil -lint "$CONTENTS/Info.plist"
codesign --verify --deep --strict "$APP"
