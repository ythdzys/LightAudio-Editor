#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
FFMPEG_VERSION="9.0.1"
LAME_VERSION="4.0"
FFMPEG_ARCHIVE="ffmpeg-${FFMPEG_VERSION}.tar.xz"
LAME_ARCHIVE="lame-${LAME_VERSION}.tar.gz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_ARCHIVE}"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/${LAME_ARCHIVE}"
FFMPEG_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
LAME_SHA256="3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"

BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/Build/BundledFFmpeg}"
SOURCE_CACHE="${SOURCE_CACHE:-$BUILD_ROOT/Sources}"
# Older Autotools releases reject source paths containing spaces. Keep disposable
# compiler output in a stable temporary path so the repository may live anywhere.
WORK_ROOT="${WORK_ROOT:-${TMPDIR:-/tmp}/LightAudioEditor-BundledFFmpeg-Work}"
OUTPUT_DIR="$ROOT_DIR/LightAudio Editor/Resources/BundledEncoder"
if [[ -z "${JOBS:-}" ]]; then
    JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || print 4)"
fi

mkdir -p "$SOURCE_CACHE" "$WORK_ROOT" "$OUTPUT_DIR"

download_and_verify() {
    local url="$1"
    local output="$2"
    local expected="$3"
    if [[ ! -f "$output" ]]; then
        curl -fL --retry 3 -o "$output" "$url"
    fi
    local actual
    actual="$(shasum -a 256 "$output" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        print -u2 "Checksum mismatch for $output"
        print -u2 "Expected: $expected"
        print -u2 "Actual:   $actual"
        exit 1
    fi
}

download_and_verify "$FFMPEG_URL" "$SOURCE_CACHE/$FFMPEG_ARCHIVE" "$FFMPEG_SHA256"
download_and_verify "$LAME_URL" "$SOURCE_CACHE/$LAME_ARCHIVE" "$LAME_SHA256"

if [[ "${SOURCE_ONLY:-0}" == "1" ]]; then
    print "Verified bundled encoder sources in $SOURCE_CACHE"
    exit 0
fi

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT/Sources"
tar -xf "$SOURCE_CACHE/$FFMPEG_ARCHIVE" -C "$WORK_ROOT/Sources"
tar -xf "$SOURCE_CACHE/$LAME_ARCHIVE" -C "$WORK_ROOT/Sources"

FFMPEG_SOURCE="$WORK_ROOT/Sources/ffmpeg-${FFMPEG_VERSION}"
LAME_SOURCE="$WORK_ROOT/Sources/lame-${LAME_VERSION}"
CLANG="$(xcrun --find clang)"
CLANGXX="$(xcrun --find clang++)"
AR="$(xcrun --find ar)"
RANLIB="$(xcrun --find ranlib)"
STRIP="$(xcrun --find strip)"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_TRIPLET="$($LAME_SOURCE/config.guess)"

# LAME 4.0's generated configure script requires pkg-config even when every
# optional pkg-config dependency is disabled. This tiny probe satisfies the
# version check and reports optional packages as unavailable.
PKG_CONFIG_STUB="$WORK_ROOT/pkg-config-stub"
cat > "$PKG_CONFIG_STUB" <<'EOF'
#!/bin/sh
case "$1" in
    --atleast-pkgconfig-version) exit 0 ;;
    --version) printf '%s\n' '0.29.2' ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$PKG_CONFIG_STUB"

build_architecture() {
    local arch="$1"
    local minimum_os="$2"
    local host_triplet="$3"
    local arch_root="$WORK_ROOT/$arch"
    local lame_build="$arch_root/lame-build"
    local lame_prefix="$arch_root/lame-prefix"
    local ffmpeg_build="$arch_root/ffmpeg-build"
    local ffmpeg_prefix="$arch_root/ffmpeg-prefix"
    local common_flags="-arch $arch -isysroot $SDK_ROOT -mmacosx-version-min=$minimum_os -O2"

    mkdir -p "$lame_build" "$lame_prefix" "$ffmpeg_build" "$ffmpeg_prefix"

    (
        cd "$lame_build"
        env \
            CC="$CLANG" \
            AR="$AR" \
            RANLIB="$RANLIB" \
            PKG_CONFIG="$PKG_CONFIG_STUB" \
            CFLAGS="$common_flags" \
            LDFLAGS="-arch $arch -isysroot $SDK_ROOT -mmacosx-version-min=$minimum_os" \
            "$LAME_SOURCE/configure" \
                --build="$BUILD_TRIPLET" \
                --host="$host_triplet" \
                --prefix="$lame_prefix" \
                --disable-shared \
                --enable-static \
                --disable-decoder \
                --disable-frontend \
                --disable-nasm \
                --disable-dependency-tracking
        make -j"$JOBS"
        make install
    )

    local cross_arguments=()
    if [[ "$arch" == "x86_64" ]]; then
        cross_arguments+=(--enable-cross-compile --disable-x86asm)
    fi

    (
        cd "$ffmpeg_build"
        "$FFMPEG_SOURCE/configure" \
            --prefix="$ffmpeg_prefix" \
            --target-os=darwin \
            --arch="$arch" \
            --sysroot="$SDK_ROOT" \
            --cc="$CLANG" \
            --cxx="$CLANGXX" \
            --host-cc="$CLANG" \
            --host-cflags="-isysroot $SDK_ROOT" \
            --host-ldflags="-isysroot $SDK_ROOT" \
            --ar="$AR" \
            --ranlib="$RANLIB" \
            --strip="$STRIP" \
            --extra-cflags="$common_flags -I$lame_prefix/include" \
            --extra-ldflags="-arch $arch -isysroot $SDK_ROOT -mmacosx-version-min=$minimum_os -L$lame_prefix/lib" \
            --disable-everything \
            --disable-autodetect \
            --disable-debug \
            --disable-doc \
            --disable-network \
            --disable-avdevice \
            --disable-swscale \
            --disable-ffplay \
            --disable-ffprobe \
            --enable-small \
            --enable-static \
            --disable-shared \
            --enable-libmp3lame \
            --enable-decoder=pcm_f32le,pcm_f64le,pcm_s16le,pcm_s24le,pcm_s32le \
            --enable-demuxer=wav \
            --enable-encoder=aac,libmp3lame,flac \
            --enable-muxer=ipod,mp3,flac \
            --enable-filter=anull,aformat,aresample \
            --enable-protocol=file,pipe \
            "${cross_arguments[@]}"
        make -j"$JOBS"
        make install
    )

    "$STRIP" -S "$ffmpeg_prefix/bin/ffmpeg"
}

build_architecture x86_64 10.15 x86_64-apple-darwin
build_architecture arm64 11.0 aarch64-apple-darwin

UNIVERSAL_BINARY="$OUTPUT_DIR/ffmpeg"
lipo -create \
    "$WORK_ROOT/x86_64/ffmpeg-prefix/bin/ffmpeg" \
    "$WORK_ROOT/arm64/ffmpeg-prefix/bin/ffmpeg" \
    -output "$UNIVERSAL_BINARY"
chmod 755 "$UNIVERSAL_BINARY"

cp "$FFMPEG_SOURCE/COPYING.LGPLv2.1" "$OUTPUT_DIR/FFmpeg-LGPL-2.1.txt"
cp "$LAME_SOURCE/COPYING" "$OUTPUT_DIR/LAME-LGPL-2.0.txt"

cat > "$OUTPUT_DIR/BUILD-INFO.txt" <<EOF
Bundled encoder build information

FFmpeg version: $FFMPEG_VERSION
FFmpeg source: $FFMPEG_URL
FFmpeg SHA-256: $FFMPEG_SHA256

LAME version: $LAME_VERSION
LAME source: $LAME_URL
LAME SHA-256: $LAME_SHA256

The helper is a separate executable built without FFmpeg's GPL or nonfree
configuration options. It contains only the audio components needed to decode
the app's temporary WAV render and encode AAC/M4A, MP3 through libmp3lame, and
FLAC. The complete reproducible build command is Scripts/build-bundled-ffmpeg.sh
in the LightAudio Editor source repository.

Architectures and deployment targets:
- x86_64: macOS 10.15
- arm64: macOS 11.0
EOF

architectures="$(lipo -archs "$UNIVERSAL_BINARY")"
for required in x86_64 arm64; do
    if [[ " $architectures " != *" $required "* ]]; then
        print -u2 "Bundled encoder is missing $required: $architectures"
        exit 1
    fi
done

if otool -L "$UNIVERSAL_BINARY" | grep -q "$WORK_ROOT"; then
    print -u2 "Bundled encoder contains a build-directory library reference."
    exit 1
fi

"$UNIVERSAL_BINARY" -hide_banner -encoders | grep -q 'libmp3lame'
"$UNIVERSAL_BINARY" -hide_banner -encoders | grep -q ' flac '
"$UNIVERSAL_BINARY" -hide_banner -encoders | grep -q ' aac '
build_configuration="$("$UNIVERSAL_BINARY" -hide_banner -buildconf 2>&1)"
if [[ "$build_configuration" == *"--enable-gpl"* || "$build_configuration" == *"--enable-nonfree"* ]]; then
    print -u2 "Bundled encoder unexpectedly enables GPL or nonfree FFmpeg components."
    exit 1
fi

print "Bundled Universal FFmpeg helper created successfully."
print "Output: $UNIVERSAL_BINARY"
print "Archs:  $architectures"
print "Size:   $(du -h "$UNIVERSAL_BINARY" | awk '{print $1}')"
