# LightAudio Editor 0.1.0 Beta 1

This is the first public beta of LightAudio Editor, a native multitrack audio editor for macOS.

## Compatibility

- Intel Macs: macOS Catalina 10.15 or later
- Apple silicon Macs: macOS Big Sur 11.0 or later
- One Universal app containing both `x86_64` and `arm64`

## Included

- Audio and audio-only video import with real cached waveforms
- Multitrack timeline editing, trimming, splitting, fades, crossfades, automation, markers, and In/Out ranges
- Track and master mixing controls, meters, mute/solo, loop playback, and clipping feedback
- Native WAV/AIFF export and optional FFmpeg-backed M4A/MP3/FLAC export
- Readable `.liau` projects, crash recovery, missing-media relinking, cleanup tools, and portable media collection

## Installing This Beta

This beta is ad-hoc signed but is not Developer ID signed or notarized. After trying to open it once, open **System Settings > Privacy & Security**, choose **Open Anyway**, and confirm. On macOS Catalina, use **System Preferences > Security & Privacy > General**. Managed Macs may not allow this override.

Do not disable Gatekeeper globally. Download the ZIP only from this repository's official GitHub release page.

## Notes

- FFmpeg is optional and must be configured in Preferences for M4A, MP3, and FLAC export.
- Imported source media is never modified.
- Please keep backups of important projects and report the steps, source format, macOS version, and Mac model when filing beta issues.
