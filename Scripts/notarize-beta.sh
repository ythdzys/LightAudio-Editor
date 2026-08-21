#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "Usage: NOTARYTOOL_PROFILE=<profile> $0 '/path/to/LightAudio Editor.app'"
    exit 64
fi

APP_PATH="${1:A}"
PROFILE="${NOTARYTOOL_PROFILE:-}"
if [[ -z "$PROFILE" ]]; then
    print -u2 "NOTARYTOOL_PROFILE is required. Store credentials with xcrun notarytool store-credentials first."
    exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "App not found: $APP_PATH"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
signature_details="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
team_id="$(print -r -- "$signature_details" | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$team_id" || "$team_id" == "not set" ]]; then
    print -u2 "The app is not signed with a Developer ID team identity."
    exit 1
fi
if [[ "$signature_details" != *"runtime"* ]]; then
    print -u2 "The app signature does not enable Hardened Runtime."
    exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
output_directory="${OUTPUT_DIR:-${APP_PATH:h}}"
final_zip="${OUTPUT_ZIP:-$output_directory/LightAudio-Editor-${version}-beta-${build}-macOS.zip}"
checksum_file="$final_zip.sha256"
if [[ -e "$final_zip" || -e "$checksum_file" ]]; then
    print -u2 "Final beta output already exists. Choose OUTPUT_ZIP to avoid overwriting it."
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/LightAudioEditorNotary.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
upload_zip="$temporary_directory/LightAudio-Editor-notary-upload.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$upload_zip"

xcrun notarytool submit "$upload_zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

mkdir -p "$output_directory"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$final_zip"
shasum -a 256 "$final_zip" > "$checksum_file"

print ""
print "Notarized beta is ready for external testing."
print "ZIP:      $final_zip"
print "Checksum: $checksum_file"
print "Team:     $team_id"
