#!/bin/zsh
# Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
# SPDX-License-Identifier: MIT
set -euo pipefail

SOURCE_DIR="${0:A:h}"
DESTINATION="${1:-$SOURCE_DIR/build}"
mkdir -p "$DESTINATION"
DESTINATION="${DESTINATION:A}"
APP="$DESTINATION/iPad to Mac Mirroring.app"
WIRELESS_RUNTIME="${2:-$SOURCE_DIR/vendor/Wireless}"
if [[ ! -x "$WIRELESS_RUNTIME/bin/uxplay" ]]; then
  print -u2 -r -- "Missing wireless runtime. Build it with scripts/build-wireless.sh, then pass its Wireless folder as the second argument."
  exit 1
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/ipad-window-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/iPad to Mac Mirroring.app/Contents/MacOS" "$STAGING/iPad to Mac Mirroring.app/Contents/Resources"
cp "$SOURCE_DIR/Info.plist" "$STAGING/iPad to Mac Mirroring.app/Contents/Info.plist"
SDK_PATH="$(xcrun --show-sdk-path)"
xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  -module-cache-path "$STAGING/module-cache" \
  -file-prefix-map "$SOURCE_DIR=." -debug-prefix-map "$SOURCE_DIR=." \
  -file-compilation-dir . \
  -framework AppKit -framework AVFoundation -framework CoreMediaIO \
  -framework CoreMedia -framework QuartzCore -framework Network \
  "$SOURCE_DIR/Main.swift" "$SOURCE_DIR/WirelessReceiver.swift" \
  "$SOURCE_DIR/WirelessVideoTransport.swift" "$SOURCE_DIR/WirelessVideo.swift" \
  -o "$STAGING/iPad to Mac Mirroring.app/Contents/MacOS/iPadToMacMirroring"

if [[ -f "$SOURCE_DIR/AppIcon.icns" ]]; then
  cp "$SOURCE_DIR/AppIcon.icns" "$STAGING/iPad to Mac Mirroring.app/Contents/Resources/AppIcon.icns"
fi
cp -R -X "$WIRELESS_RUNTIME" "$STAGING/iPad to Mac Mirroring.app/Contents/Resources/Wireless"
for DOCUMENT in LICENSE NOTICE COPYING.GPL-3.0 LICENSES.md THIRD-PARTY-NOTICES.txt SECURITY.txt; do
  cp "$SOURCE_DIR/$DOCUMENT" "$STAGING/iPad to Mac Mirroring.app/Contents/Resources/$DOCUMENT"
done
# The backend build signs its relocated Mach-O files. Preserve those signatures;
# sign the enclosing app only after all resources are in place.
codesign --force --sign - --identifier local.ipad-to-mac-mirroring "$STAGING/iPad to Mac Mirroring.app"
ditto --norsrc --noextattr "$STAGING/iPad to Mac Mirroring.app" "$APP"
# File Provider can add Finder metadata when a bundle is copied into Documents.
# Remove only unsigned presentation metadata from this generated app.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
print -r -- "Built: $APP"
