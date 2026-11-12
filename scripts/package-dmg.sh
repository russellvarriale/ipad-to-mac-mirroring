#!/bin/zsh
# Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
PRODUCT="iPad to Mac Mirroring"
APP="${1:-$PROJECT_ROOT/build/$PRODUCT.app}"
DESTINATION="${2:-$PROJECT_ROOT/dist}"
if [[ ! -d "$APP/Contents" ]]; then
  print -u2 -r -- "App not found: $APP. Build it first with ./build.sh."
  exit 1
fi
APP="${APP:A}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]]; then
  print -u2 -r -- "Unexpected app version; refusing to construct a release filename."
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" != "local.ipad-to-mac-mirroring" ]]; then
  print -u2 -r -- "Unexpected app bundle identifier."
  exit 1
fi
mkdir -p "$DESTINATION"
DESTINATION="${DESTINATION:A}"
IMAGE="$DESTINATION/iPad-to-Mac-Mirroring-$VERSION-arm64.dmg"
if [[ -e "$IMAGE" ]]; then
  print -u2 -r -- "Refusing to replace an existing release: $IMAGE"
  exit 1
fi
DMG_STAGING="$(mktemp -d /private/tmp/ipad-to-mac-dmg.XXXXXX)"
DMG_MOUNTED=0
DMG_MOUNT_POINT="$DMG_STAGING/mounted"
cleanup_dmg() {
  if (( DMG_MOUNTED )); then
    if ! hdiutil detach "$DMG_MOUNT_POINT"; then
      print -u2 -r -- "Could not detach the temporary image; staging was retained at $DMG_STAGING"
      return
    fi
  fi
  rm -rf "$DMG_STAGING"
}
trap cleanup_dmg EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir "$DMG_STAGING/payload"
STAGED_APP="$DMG_STAGING/payload/$PRODUCT.app"
# Package a clean copy of the reviewed build. The recipient's browser/macOS
# applies its own download quarantine and Gatekeeper checks to this release.
ditto --norsrc --noextattr "$APP" "$STAGED_APP"
xattr -dr com.apple.FinderInfo "$STAGED_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$STAGED_APP" 2>/dev/null || true
codesign --verify --deep --strict "$STAGED_APP"
ln -s /Applications "$DMG_STAGING/payload/Applications"
cat > "$DMG_STAGING/payload/Read Me.txt" <<'INSTALL_NOTES_EOF'
iPad to Mac Mirroring

INSTALL
1. Drag iPad to Mac Mirroring.app onto the Applications shortcut.
2. Eject this disk image.
3. Open the app from Applications.

REQUIREMENTS
Apple silicon Mac (M1 or later), macOS 14 or later.
No Xcode, command-line tools, Homebrew, Python or Terminal is needed to run it.

PREVIEW SIGNING STATUS
This build is locally ad-hoc signed and has not been notarized by Apple.
macOS may block its first launch. Only proceed if you trust this project and
have verified the download. Apple's instructions explain the available
per-app approval in System Settings > Privacy & Security:
https://support.apple.com/en-us/102445
A DMG does not remove Gatekeeper checks. Some managed Macs may prohibit
unnotarized apps. Developer ID signing/notarization is separate release work.

USB AND WI-FI
Use a data-capable USB cable and allow Camera access for Apple's iPad screen
source, or select Wi-Fi and start the receiver on a trusted local network.
Allow Local Network access when asked. Use your recording app for recording,
your camera and your microphone. This app is a video-only local viewer.

SOURCE AND LICENSES
Original author: Russell Varriale
https://github.com/russellvarriale/ipad-to-mac-mirroring
Original app code is MIT-licensed; the UxPlay receiver/native integration is
GPL-3.0-or-later. Applicable notices are included in the app's Resources.
The matching app source, native corresponding-source archive and checksums
are provided beside the DMG in the GitHub release.
INSTALL_NOTES_EOF
# Keep image creation away from cloud/File Provider output folders until the
# disk image is fully closed and verified.
STAGED_IMAGE="$DMG_STAGING/release.dmg"
# Build the HFS+ filesystem directly, without mounting a writable staging
# volume, then convert it to a standard compressed read-only DMG.
HFS_IMAGE="$DMG_STAGING/payload-hfs.dmg"
hdiutil makehybrid -hfs -hfs-volume-name "$PRODUCT" \
  -o "$HFS_IMAGE" "$DMG_STAGING/payload"
# DiscRecording supplies Finder metadata while building HFS+. Clear only that
# unsigned presentation metadata from this generated image, preserving the
# existing app signatures and all code bytes.
WRITABLE_IMAGE="$DMG_STAGING/writable.dmg"
hdiutil convert "$HFS_IMAGE" -format UDRW -o "$WRITABLE_IMAGE"
mkdir "$DMG_MOUNT_POINT"
# Mark ownership before attach: a partially successful attach must never let
# cleanup recurse into a possibly mounted volume.
DMG_MOUNTED=1
hdiutil attach -readwrite -nobrowse -mountpoint "$DMG_MOUNT_POINT" "$WRITABLE_IMAGE"
MOUNTED_APP="$DMG_MOUNT_POINT/$PRODUCT.app"
xattr -dr com.apple.FinderInfo "$MOUNTED_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$MOUNTED_APP" 2>/dev/null || true
codesign --verify --deep --strict "$MOUNTED_APP"
hdiutil detach "$DMG_MOUNT_POINT"
DMG_MOUNTED=0
hdiutil convert "$WRITABLE_IMAGE" -format UDZO -imagekey zlib-level=9 -o "$STAGED_IMAGE"
hdiutil verify "$STAGED_IMAGE"
mkdir -p "$DMG_MOUNT_POINT"
DMG_MOUNTED=1
hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT_POINT" "$STAGED_IMAGE"
codesign --verify --deep --strict "$DMG_MOUNT_POINT/$PRODUCT.app"
if [[ ! -L "$DMG_MOUNT_POINT/Applications" || "$(readlink "$DMG_MOUNT_POINT/Applications")" != /Applications ]]; then
  print -u2 -r -- "The image is missing its Applications shortcut."
  exit 1
fi
hdiutil detach "$DMG_MOUNT_POINT"
DMG_MOUNTED=0
mv -n "$STAGED_IMAGE" "$IMAGE"
if [[ -e "$STAGED_IMAGE" ]]; then
  print -u2 -r -- "The release destination appeared during packaging; it was not overwritten."
  exit 1
fi
print -r -- "Created: $IMAGE"
print -r -- "No Developer ID signature or notarization was added by this packaging script."
