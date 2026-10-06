#!/usr/bin/env bash
# Builds Utilities/<Name> into build/<Name>.app, build/<Name>.dmg and build/<Name>.zip.
#
#   scripts/build-app.sh <Name>                    universal release build, ad hoc signed
#   scripts/build-app.sh <Name> --dev              debug build as <bundle id>.dev, signed with your
#                                                  Apple Development identity (permissions survive rebuilds)
#   scripts/build-app.sh <Name> --release X.Y.Z    Developer ID signed, notarized and stapled
#
# --release signs with SIGN_IDENTITY (default: Christophe's Developer ID) and notarizes with an
# App Store Connect API key: APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID, APPLE_API_ISSUER.
# On Chris's Mac they default to the key in ~/.otter-mail/signing.
set -euo pipefail
cd "$(dirname "$0")/.."

name="${1:?usage: scripts/build-app.sh <Name> [--dev | --release X.Y.Z]}"
shift
mode=local
version=0.0.0
case "${1:-}" in
  --dev) mode=dev ;;
  --release) mode=release; version="${2:?--release needs a version}" ;;
  "") ;;
  *) echo "Unknown option $1" >&2; exit 1 ;;
esac

dir="Utilities/$name"
[[ -f "$dir/Info.plist" ]] || { echo "No utility at $dir" >&2; exit 1; }
app="build/$name.app"
zip="build/$name.zip"
plist="$app/Contents/Info.plist"
buddy=/usr/libexec/PlistBuddy

if [[ $mode == dev ]]; then
  swift build --product "$name"
  bin="$(swift build --show-bin-path)/$name"
else
  swift build -c release --product "$name" --arch arm64 --arch x86_64
  bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$name"
fi

rm -rf "$app" "$zip" "build/$name.dmg"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
cp "$dir/Info.plist" "$plist"
if [[ -d "$dir/Resources" ]]; then cp -R "$dir/Resources/." "$app/Contents/Resources/"; fi
$buddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" "$plist"
# Releases are tagged <id>-vX.Y.Z; the updater finds its own by this.
id="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
$buddy -c "Add :UtilityID string $id" "$plist"

case $mode in
  dev)
    bundle_id="$($buddy -c "Print :CFBundleIdentifier" "$plist")"
    $buddy -c "Set :CFBundleIdentifier $bundle_id.dev" "$plist"
    identity="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
    codesign --force --sign "${identity:--}" "$app"
    ;;
  local)
    codesign --force --sign - "$app"
    ;;
  release)
    identity="${SIGN_IDENTITY:-Developer ID Application: Christophe Nicolas Kafrouni (838JVGY7W4)}"
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
    ;;
esac
codesign --verify --strict "$app"

# A DMG to install from (the app beside an Applications link), and the zip the updater downloads.
dmg="build/$name.dmg"
staging="build/dmg-$name"
rm -rf "$dmg" "$staging"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "$name" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$staging"

if [[ $mode == release ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
  key_id="${APPLE_API_KEY_ID:-WJLY8WGR4C}"
  key="${APPLE_API_KEY:-$HOME/.otter-mail/signing/AuthKey_$key_id.p8}"
  issuer="${APPLE_API_ISSUER:-b010c56a-fe59-481d-a7db-7350e51eb8b8}"
  # Notarizing the DMG covers the app in it too: staple the ticket to both.
  xcrun notarytool submit "$dmg" --key "$key" --key-id "$key_id" --issuer "$issuer" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose "$app"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
ditto -c -k --keepParent "$app" "$zip"

echo "Built $app ($version)"
