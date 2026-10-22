#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
PROJECT_PATH="$ROOT_DIR/LightAudio Editor.xcodeproj"
SCHEME="LightAudio Editor"
VERSION="${MARKETING_VERSION:-0.2.0}"
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-5}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.ythdzys.LightAudioEditor}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/Build/Beta/${VERSION}-${BUILD_NUMBER}-${TIMESTAMP}}"
ARCHIVE_PATH="$BUILD_ROOT/LightAudio Editor.xcarchive"
DIST_APP="$BUILD_ROOT/LightAudio Editor.app"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
BUNDLED_ENCODER="$ROOT_DIR/LightAudio Editor/Resources/BundledEncoder/ffmpeg"
BUNDLED_ENCODER_SOURCE_CACHE="$ROOT_DIR/Build/BundledFFmpeg/Sources"

if [[ -e "$BUILD_ROOT" ]]; then
    print -u2 "Build output already exists: $BUILD_ROOT"
    print -u2 "Choose a different BUILD_ROOT so an earlier beta is never overwritten."
    exit 1
fi

mkdir -p "$BUILD_ROOT"

if [[ ! -x "$BUNDLED_ENCODER" ]]; then
    print "Bundled encoder is missing; building it before packaging."
    BUILD_ROOT="$ROOT_DIR/Build/BundledFFmpeg" "$ROOT_DIR/Scripts/build-bundled-ffmpeg.sh"
fi

# Keep the exact corresponding source beside every distributable artifact. This
# makes the FFmpeg/LAME LGPL source offer concrete and reproducible.
BUILD_ROOT="$ROOT_DIR/Build/BundledFFmpeg" SOURCE_ONLY=1 "$ROOT_DIR/Scripts/build-bundled-ffmpeg.sh"
ENCODER_SOURCE_PACKAGE="$BUILD_ROOT/LightAudio-Editor-${VERSION}-Bundled-Encoder-Source"
mkdir -p "$ENCODER_SOURCE_PACKAGE"
cp "$BUNDLED_ENCODER_SOURCE_CACHE/ffmpeg-9.0.1.tar.xz" "$ENCODER_SOURCE_PACKAGE/"
cp "$BUNDLED_ENCODER_SOURCE_CACHE/lame-4.0.tar.gz" "$ENCODER_SOURCE_PACKAGE/"
cp "$ROOT_DIR/Scripts/build-bundled-ffmpeg.sh" "$ENCODER_SOURCE_PACKAGE/"
cp "$ROOT_DIR/ThirdParty/FFmpeg/README.md" "$ENCODER_SOURCE_PACKAGE/README.md"

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

DIST_ENCODER="$DIST_APP/Contents/Resources/BundledEncoder/ffmpeg"
if [[ ! -x "$DIST_ENCODER" ]]; then
    print -u2 "The archive did not contain the bundled encoder helper."
    exit 1
fi

DIST_LICENSE="$DIST_APP/Contents/Resources/LICENSE"
DIST_NOTICE="$DIST_APP/Contents/Resources/NOTICE"
if ! cmp -s "$ROOT_DIR/LICENSE" "$DIST_LICENSE" || ! cmp -s "$ROOT_DIR/NOTICE" "$DIST_NOTICE"; then
    print -u2 "The archive did not contain the current application license and notice."
    exit 1
fi

if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DIST_ENCODER"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DIST_APP"
else
    # Seal the complete bundle so Apple silicon and Intel testers receive a
    # self-consistent app even though Gatekeeper cannot establish its author.
    codesign --force --sign - --timestamp=none "$DIST_ENCODER"
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
    xcrun vtool -show-build -arch "$2" "$1" | awk '$1 == "minos" { print $2; exit }'
}

intel_minimum_os="$(minimum_os_for_architecture "$EXECUTABLE" x86_64)"
arm_minimum_os="$(minimum_os_for_architecture "$EXECUTABLE" arm64)"
if [[ "$intel_minimum_os" != "10.15" ]]; then
    print -u2 "Release validation failed: x86_64 must target macOS 10.15, found $intel_minimum_os."
    exit 1
fi

encoder_architectures="$(lipo -archs "$DIST_ENCODER")"
for required_architecture in arm64 x86_64; do
    if [[ " $encoder_architectures " != *" $required_architecture "* ]]; then
        print -u2 "Bundled encoder validation failed: missing $required_architecture from: $encoder_architectures"
        exit 1
    fi
done
encoder_intel_minimum_os="$(minimum_os_for_architecture "$DIST_ENCODER" x86_64)"
encoder_arm_minimum_os="$(minimum_os_for_architecture "$DIST_ENCODER" arm64)"
if [[ "$encoder_intel_minimum_os" != "10.15" || "$encoder_arm_minimum_os" != "11.0" ]]; then
    print -u2 "Bundled encoder deployment-target validation failed."
    exit 1
fi
for required_encoder in aac flac libmp3lame; do
    if ! "$DIST_ENCODER" -hide_banner -encoders | awk '{ print $2 }' | grep -Fx "$required_encoder" >/dev/null; then
        print -u2 "Bundled encoder validation failed: missing $required_encoder."
        exit 1
    fi
done
encoder_build_configuration="$("$DIST_ENCODER" -hide_banner -buildconf 2>&1)"
if [[ "$encoder_build_configuration" == *"--enable-gpl"* || "$encoder_build_configuration" == *"--enable-nonfree"* ]]; then
    print -u2 "Bundled encoder validation failed: GPL or nonfree FFmpeg components are enabled."
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
codesign --verify --strict --verbose=2 "$DIST_ENCODER"
if [[ -z "$IDENTITY" ]]; then
    signature_details="$(codesign -dvvv "$DIST_APP" 2>&1)"
    if [[ "$signature_details" != *"Signature=adhoc"* ]]; then
        print -u2 "Release validation failed: the test build is not ad-hoc signed."
        exit 1
    fi
fi

ZIP_PATH="$BUILD_ROOT/LightAudio-Editor-${VERSION}-beta-${BUILD_NUMBER}-${artifact_suffix}.zip"
ENCODER_SOURCE_ZIP="$BUILD_ROOT/LightAudio-Editor-${VERSION}-Bundled-Encoder-Source.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$ENCODER_SOURCE_PACKAGE" "$ENCODER_SOURCE_ZIP"

print ""
print "Beta archive created successfully."
print "App:     $DIST_APP"
print "ZIP:     $ZIP_PATH"
print "Sources: $ENCODER_SOURCE_ZIP"
print "Version: $actual_version ($actual_build)"
print "Bundle:  $actual_bundle_id"
print "Archs:   $architectures"
print "Encoder: $encoder_architectures (AAC, MP3, FLAC)"
print "Minimum: macOS $intel_minimum_os (Intel), macOS $arm_minimum_os (Apple silicon)"
if [[ -n "$IDENTITY" ]]; then
    print "Next: NOTARYTOOL_PROFILE=LightAudioEditor-notary ./Scripts/notarize-beta.sh \"$DIST_APP\""
else
    print "This artifact is ad-hoc signed and unnotarized. Testers must approve it in Privacy & Security."
fi
