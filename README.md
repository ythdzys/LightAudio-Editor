<p align="center">
  <img src="LightAudio%20Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="LightAudio Editor app icon">
</p>

<h1 align="center">LightAudio Editor</h1>

<p align="center">
  A lightweight, native multitrack audio editor for macOS.<br>
  Built with Swift, AppKit, AVFoundation, and AVFAudio.
</p>

LightAudio Editor provides a professional timeline-oriented workflow for arranging, trimming, mixing, and exporting audio. Video files can be imported as audio-only sources, while original media remains untouched throughout the editing process.

The app targets **macOS Catalina 10.15 and later** and uses the readable JSON-based `.liau` project format.

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
| Optional export | M4A/AAC, MP3, FLAC | User-provided FFmpeg |

Actual decoding support depends on the codecs available to AVFoundation on the current macOS version. MP4, MOV, and M4V provide the most reliable video-origin import path. Video is never displayed or edited; only its audio stream is used.

For compressed export, install FFmpeg and select or test its executable in **LightAudio Editor > Preferences**. The app also checks common Homebrew locations automatically:

```bash
brew install ffmpeg
```

FFmpeg is optional. The app launches and native WAV/AIFF export remains available without it.

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

- macOS 10.15 or later
- A recent Xcode release with the macOS SDK
- Swift 5 toolchain
- FFmpeg only if M4A, MP3, or FLAC export is required

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

Current verification: **43 tests passing**.

## Current Limitations

- No video preview or video editing features
- No Audio Unit, VST, or other plug-in hosting
- Three-band EQ exists only as a future-compatible project model and is not processed
- Normalize-on-export is not implemented; the export option remains disabled
- M4A, MP3, and FLAC export require a compatible external FFmpeg build
- No signed or notarized release package is currently published; build the app from source

## Technology

- Swift 5
- AppKit
- AVFoundation / AVFAudio / AVAudioEngine
- CryptoKit for stable cache and metadata identities
- Optional FFmpeg integration through a replaceable export backend
