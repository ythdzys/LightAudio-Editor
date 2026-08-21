# Bundled FFmpeg Helper

LightAudio Editor distributes a narrowly configured FFmpeg command-line helper
for AAC/M4A, MP3, and FLAC export. The helper runs as a separate process and is
not linked into the Swift application.

## Versions

- FFmpeg 9.0.1, LGPL 2.1 or later
- LAME 4.0, GNU Library General Public License 2

The exact source URLs, SHA-256 checksums, configure options, architecture
targets, and output validation are recorded in
`Scripts/build-bundled-ffmpeg.sh`. The generated notices are copied into the
app beside the helper under `Contents/Resources/BundledEncoder`.

## Rebuilding

```bash
./Scripts/build-bundled-ffmpeg.sh
```

The script downloads and verifies the corresponding source archives, builds
separate Intel and Apple silicon binaries, combines them with `lipo`, and
writes the result to `LightAudio Editor/Resources/BundledEncoder/ffmpeg`.

Do not replace the helper with an arbitrary precompiled FFmpeg binary. A
replacement must be audited for architecture support, deployment targets,
enabled codecs, and the licenses of every included component.
