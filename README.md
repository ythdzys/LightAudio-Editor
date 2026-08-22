<p align="center">
  <img src="LightAudio%20Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="LightAudio Editor app icon">
</p>

<h1 align="center">LightAudio Editor</h1>

<p align="center">
  A lightweight, native multitrack audio editor for macOS.<br>
  Built with Swift, AppKit, AVFoundation, and AVFAudio.
</p>

LightAudio Editor provides a professional timeline-oriented workflow for arranging, trimming, mixing, and exporting audio. Video files can be imported as audio-only sources, while original media remains untouched throughout the editing process.

The Universal app supports **Intel Macs on macOS Catalina 10.15 and later** and **Apple silicon Macs on macOS Big Sur 11.0 and later**. Apple silicon starts at Big Sur; no Apple silicon Mac can run Catalina. LightAudio Editor uses the readable, versioned JSON-based `.liau` project format, and `.liau` files can be opened from Finder or from the app.

## Highlights

- Native AppKit interface with a media bin, fixed track headers, scrollable timeline, inspector, toolbar, and status area
- Multiple audio tracks with reorder, collapse, height adjustment, mute, solo, lock, volume, pan, and level meters
- Real waveform analysis and persistent caching for audio and video-origin proxy media
- Drag-and-drop import from Finder and direct placement from the media bin onto existing or automatically created tracks
- Non-destructive clip move, trim, split, duplicate, ripple delete, fades, crossfades, gain, pan, naming, and color labels
- Multi-selection, marquee selection, grouped movement, clipboard editing, snapping, markers, and undo/redo
- Clip volume automation envelopes with editable keyframes applied during playback and export
- Smooth playback with seeking, audible fades, metering, clipping feedback, loop ranges, and follow-playhead mode
- Full-project or In/Out range export to WAV, AIFF, M4A, MP3, and FLAC
- Crash recovery, missing-media relinking, portable media collection, and project cleanup tools

## Import and Export

| Direction | Formats | Backend |
| --- | --- | --- |
| Audio import | MP3, WAV, M4A, AAC, FLAC, AIFF/AIF, CAF | AVFoundation / AVAudioFile |
| Video import | MP4, MOV, M4V, MKV, AVI | Audio-only proxy through AVFoundation |
| Native export | WAV, AIFF | Built-in renderer |
| Compressed/lossless export | M4A/AAC, MP3, FLAC | Bundled Universal FFmpeg helper |

Actual decoding support depends on the codecs available to AVFoundation on the current macOS version. MP4, MOV, and M4V provide the most reliable video-origin import path. Video is never displayed or edited; only its audio stream is used.

M4A, MP3, and FLAC work without a separate install or preference setting. LightAudio Editor includes a narrowly configured LGPL FFmpeg/LAME command-line helper for Intel and Apple silicon Macs, validates it in the background at launch, and uses it automatically for compressed export.

MP3 export accepts LAME-compatible sample rates up to 48 kHz. If the project default or a previously selected rate is not compatible with MP3, the export panel selects 48 kHz automatically and validates the setting before rendering begins. WAV, AIFF, M4A, and FLAC retain the higher sample-rate options.

## Timeline Editing

The timeline supports:

- Clip placement across multiple tracks, including automatic track creation when media is dropped below the last track
- Move, source trim, split, duplicate, Option-drag duplicate, delete, ripple delete, and arrow-key nudge
- Command-click and Shift-click multi-selection, plus drag marquee selection
- Copy, cut, and paste at the playhead while preserving relative track and timing relationships
- Playhead, clip-edge, marker, and grid snapping with a visible snap guide
- Linear, equal-power, ease-in, and ease-out fade curves
- Explicit linear or equal-power crossfades between overlapping clips
- Clip and track gain/pan, master volume, per-track meters, master metering, and clipping indication
- Clip volume automation keyframes with linear interpolation
- In/Out points, loop playback, markers, track collapse/reorder, variable track height, and zoom-to-fit
- Smooth pointer-anchored trackpad pinch zoom over a wide timeline range
- Catalina-safe horizontal scrolling that redraws newly exposed timeline content without waiting for a window resize

Locked tracks remain audible but reject editing, pasting, trimming, deletion, and media drops. Mute and solo state is applied consistently during playback, metering, and export.

## Projects and Media Safety

`.liau` files are readable JSON documents containing timeline structure, media references, mix settings, markers, view state, and automation. They do not embed source audio, waveform arrays, or video proxies.

- Original media is never modified by editing, normalization, proxy generation, or export.
- Relative media paths are saved when possible.
- Missing media remains represented in the project and can be relinked individually or by locating a folder.
- Editing, playback, and export are intentionally blocked until all missing media has been relinked.
- **File > Collect Project Media** creates a portable copy containing a `.liau` project and a `Media/` folder.
- Export cannot overwrite imported source media or generated proxies.

## Recovery and Caches

App-generated data is stored outside both the `.app` bundle and `.liau` project files:

```text
~/Library/Application Support/LightAudio Editor/
|-- Media Proxies/
|-- Recovery/
`-- Waveforms/
```

Waveform and proxy caches are validated against source identity and regenerated when stale. Recovery snapshots are created only for dirty projects that have a real saved project path. After an unexpected shutdown, a newer unconsumed snapshot can be restored or declined.

**LightAudio Editor > Preferences > Clear App Cache** removes waveform caches, proxy audio, and recovery snapshots. It never removes `.liau` projects or original media, and cache clearing is blocked while an export is active.

## Build from Source

Requirements:

- Intel Mac: macOS 10.15 or later
- Apple silicon Mac: macOS 11.0 or later
- A recent Xcode release with the macOS SDK
- Swift 5 toolchain

Clone and open the project:

```bash
git clone https://github.com/ythdzys/LightAudio-Editor.git
cd LightAudio-Editor
open "LightAudio Editor.xcodeproj"
```

Select the **LightAudio Editor** scheme and run it on **My Mac**, or build from Terminal:

```bash
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  build
```

The built app is written to:

```text
Build/DerivedData/Build/Products/Debug/LightAudio Editor.app
```

## Beta Distribution

Beta 2 is version `0.1.1` build `2` and uses bundle identifier `com.ythdzys.LightAudioEditor`. The repository includes scripts for a single Universal `arm64`/`x86_64` archive, Developer ID signing, Apple notarization, ticket stapling, Gatekeeper validation, and ZIP packaging. Packaging fails if the app or bundled encoder is missing either architecture, if the required compressed-audio encoders are unavailable, or if the Intel and Apple silicon slices do not retain their macOS 10.15 and 11.0 minimum versions respectively.

See [BETA_RELEASE.md](BETA_RELEASE.md) for packaging instructions and the optional Apple Developer setup. Without a Developer ID identity, the script seals the complete app with an ad-hoc signature and labels the ZIP `ADHOC-UNNOTARIZED`; testers must approve that build once in **Privacy & Security**. Developer ID signing and notarization remain the recommended path for public distribution.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `Space` | Play or pause |
| `Command-S` | Save project |
| `Command-O` | Open project |
| `Command-I` | Import media |
| `Command-E` | Export |
| `Command-Z` / `Shift-Command-Z` | Undo / redo |
| `Command-C` / `Command-X` / `Command-V` | Copy / cut / paste clips |
| `Command-D` | Duplicate selected clips |
| `Delete` | Delete selected clips or keyframe |
| `S` or `Command-B` | Toggle razor tool |
| `I` / `O` | Set In / Out point |
| `Option-X` | Clear In/Out range |
| `L` | Toggle loop range |
| `M` | Add marker |
| `Shift-M` / `Shift-Option-M` | Next / previous marker |
| `N` | Toggle snapping |
| `Command-=` / `Command--` | Zoom in / out |
| `Option-Command-=` / `Option-Command--` | Increase / decrease track height |
| `Left Arrow` / `Right Arrow` | Nudge selected clips |
| `Option-Left Arrow` / `Option-Right Arrow` | Previous / next clip edge |
| `Home` / `End` | Jump to project start / end |

Standard macOS shortcuts also apply to New, Save As, Preferences, and window commands.

## Architecture

```text
LightAudio Editor/
|-- App/         App lifecycle, main window, project coordination, recovery
|-- Models/      Project, media, timeline, clip, track, waveform, export data
|-- Services/    Import, relink, proxy, waveform, playback, render, export, cache
|-- UI/          Media bin, timeline, clip, track header, inspector, dialogs
`-- Utilities/   Timecode, format helpers, metadata hashing
```

The playback and native export paths share the same timeline audio-source processing model so trims, automation, fades, crossfades, clip/track mix controls, and master gain remain closely aligned.

## Tests

The regression suite covers project validation, recovery state, relinking, editing and undo behavior, automation, crossfades, rendering, export safety, cancellation, and cache-sensitive workflows.

```bash
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  test
```

Current verification: **59 tests passing** on both Apple silicon and Intel build paths, including timeline scroll invalidation and real bundled M4A, MP3, and FLAC exports.

## Current Limitations

- No video preview or video editing features
- No Audio Unit, VST, or other plug-in hosting
- Three-band EQ exists only as a future-compatible project model and is not processed
- Normalize-on-export is not implemented; the export option remains disabled
- The bundled encoder is intentionally limited to AAC/M4A, MP3, and FLAC output from LightAudio Editor's rendered WAV mix; it is not a general-purpose FFmpeg distribution
- Beta packages are ad-hoc signed and unnotarized; Gatekeeper approval is required on first launch

## Technology

- Swift 5
- AppKit
- AVFoundation / AVFAudio / AVAudioEngine
- CryptoKit for stable cache and metadata identities
- Bundled Universal FFmpeg/LAME helper through an internal process-based export backend

## Bundled Encoder and Licensing

The included helper uses FFmpeg 9.0.1 and LAME 4.0, built without FFmpeg's GPL or nonfree configure options. License texts and exact build metadata ship in the app under `Contents/Resources/BundledEncoder`, and the reproducible build is documented in [ThirdParty/FFmpeg/README.md](ThirdParty/FFmpeg/README.md).

```bash
./Scripts/build-bundled-ffmpeg.sh
```

`Scripts/build-beta.sh` also prepares a corresponding-source ZIP containing the verified upstream source archives and build recipe. Publish that source ZIP beside every beta binary that contains the helper.
