#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
PROJECT_PATH="$ROOT_DIR/LightAudio Editor.xcodeproj"
SCHEME="LightAudio Editor"
VERSION="${MARKETING_VERSION:-0.1.1}"
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-2}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.ythdzys.LightAudioEditor}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/Build/Beta/${VERSION}-${BUILD_NUMBER}-${TIMESTAMP}}"
ARCHIVE_PATH="$BUILD_ROOT/LightAudio Editor.xcarchive"
DIST_APP="$BUILD_ROOT/LightAudio Editor.app"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"

if [[ -e "$BUILD_ROOT" ]]; then
    print -u2 "Build output already exists: $BUILD_ROOT"
    print -u2 "Choose a different BUILD_ROOT so an earlier beta is never overwritten."
    exit 1
fi

mkdir -p "$BUILD_ROOT"

signing_arguments=()
artifact_suffix="ADHOC-UNNOTARIZED"
if [[ -n "$IDENTITY" ]]; then
    if [[ -z "$TEAM_ID" ]]; then
        print -u2 "APPLE_TEAM_ID is required when DEVELOPER_ID_APPLICATION is set."
        exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -F -- "\"$IDENTITY\"" >/dev/null; then
        print -u2 "The requested Developer ID identity is not installed in the login keychain:"
        print -u2 "  $IDENTITY"
        exit 1
    fi
    signing_arguments=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=$IDENTITY"
        "DEVELOPMENT_TEAM=$TEAM_ID"
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
    artifact_suffix="SIGNED-NOT-NOTARIZED"
else
    signing_arguments=("CODE_SIGNING_ALLOWED=NO")
    print "No Developer ID identity supplied. Building an ad-hoc-signed universal beta."
fi

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    "ARCHS=arm64 x86_64" \
    "ONLY_ACTIVE_ARCH=NO" \
    "MARKETING_VERSION=$VERSION" \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
    "${signing_arguments[@]}"

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/LightAudio Editor.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
    print -u2 "The archive did not contain LightAudio Editor.app."
    exit 1
fi

ditto "$ARCHIVED_APP" "$DIST_APP"

if [[ -z "$IDENTITY" ]]; then
    # Seal the complete bundle so Apple silicon and Intel testers receive a
    # self-consistent app even though Gatekeeper cannot establish its author.
    codesign --force --sign - --timestamp=none "$DIST_APP"
fi

EXECUTABLE="$DIST_APP/Contents/MacOS/LightAudio Editor"
architectures="$(lipo -archs "$EXECUTABLE")"
for required_architecture in arm64 x86_64; do
    if [[ " $architectures " != *" $required_architecture "* ]]; then
        print -u2 "Release validation failed: missing $required_architecture from: $architectures"
        exit 1
    fi
done

minimum_os_for_architecture() {
    xcrun vtool -show-build -arch "$1" "$EXECUTABLE" | awk '$1 == "minos" { print $2; exit }'
}

intel_minimum_os="$(minimum_os_for_architecture x86_64)"
arm_minimum_os="$(minimum_os_for_architecture arm64)"
if [[ "$intel_minimum_os" != "10.15" ]]; then
    print -u2 "Release validation failed: x86_64 must target macOS 10.15, found $intel_minimum_os."
    exit 1
fi
if [[ "$arm_minimum_os" != "11.0" ]]; then
    print -u2 "Release validation failed: arm64 must target macOS 11.0, found $arm_minimum_os."
    exit 1
fi

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIST_APP/Contents/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DIST_APP/Contents/Info.plist")"
actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DIST_APP/Contents/Info.plist")"
declared_intel_minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersionByArchitecture:x86_64' "$DIST_APP/Contents/Info.plist")"
declared_arm_minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersionByArchitecture:arm64' "$DIST_APP/Contents/Info.plist")"
if [[ "$actual_version" != "$VERSION" || "$actual_build" != "$BUILD_NUMBER" || "$actual_bundle_id" != "$BUNDLE_ID" ||
      "$declared_intel_minimum_os" != "$intel_minimum_os" || "$declared_arm_minimum_os" != "$arm_minimum_os" ]]; then
    print -u2 "Release metadata validation failed."
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$DIST_APP"
if [[ -z "$IDENTITY" ]]; then
    signature_details="$(codesign -dvvv "$DIST_APP" 2>&1)"
    if [[ "$signature_details" != *"Signature=adhoc"* ]]; then
        print -u2 "Release validation failed: the test build is not ad-hoc signed."
        exit 1
    fi
fi

ZIP_PATH="$BUILD_ROOT/LightAudio-Editor-${VERSION}-beta-${BUILD_NUMBER}-${artifact_suffix}.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "$ZIP_PATH"

print ""
print "Beta archive created successfully."
print "App:     $DIST_APP"
print "ZIP:     $ZIP_PATH"
print "Version: $actual_version ($actual_build)"
print "Bundle:  $actual_bundle_id"
print "Archs:   $architectures"
print "Minimum: macOS $intel_minimum_os (Intel), macOS $arm_minimum_os (Apple silicon)"
if [[ -n "$IDENTITY" ]]; then
    print "Next: NOTARYTOOL_PROFILE=LightAudioEditor-notary ./Scripts/notarize-beta.sh \"$DIST_APP\""
else
    print "This artifact is ad-hoc signed and unnotarized. Testers must approve it in Privacy & Security."
fi
