<p align="center">
  <img src="LightAudio%20Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="LightAudio Editor app icon">
</p>

<h1 align="center">LightAudio Editor</h1>

<p align="center">
  A lightweight, native multitrack audio editor for macOS.<br>
  Built with Swift, AppKit, AVFoundation, and AVFAudio.
</p>

<p align="center">
  <a href="https://github.com/ythdzys/LightAudio-Editor/releases/tag/v0.1.1-beta.2"><strong>Download Beta 2</strong></a>
  &nbsp;|&nbsp;
  <a href="https://github.com/ythdzys/LightAudio-Editor/issues/new/choose">Report an issue</a>
  &nbsp;|&nbsp;
  <a href="Docs/Beta-Release.md">Release guide</a>
</p>

<p align="center">
  <img alt="macOS 10.15 or later" src="https://img.shields.io/badge/macOS-10.15%2B-black?logo=apple">
  <img alt="Universal Intel and Apple silicon" src="https://img.shields.io/badge/Mac-Intel%20%2B%20Apple%20silicon-555555">
  <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white">
  <img alt="Beta release" src="https://img.shields.io/badge/status-public%20beta-e6a700">
</p>

LightAudio Editor provides a timeline-oriented workflow for importing, arranging, trimming, mixing, and exporting audio. Video files are treated as audio-only sources: the app creates a reusable audio proxy and never presents video editing controls. All edits are non-destructive and original media is left untouched.

> [!IMPORTANT]
> LightAudio Editor is beta software. Keep backups of important `.liau` projects and source media. The current public build is ad-hoc signed and not notarized, so macOS requires one-time approval before first launch.

## Download and Install

1. Open the [Beta 2 release](https://github.com/ythdzys/LightAudio-Editor/releases/tag/v0.1.1-beta.2).
2. Download `LightAudio-Editor-0.1.1-beta-2-ADHOC-UNNOTARIZED.zip`.
3. Extract the ZIP and move **LightAudio Editor.app** to `/Applications`.
4. Try to open the app once. If macOS blocks it, approve it under:
   - macOS Ventura and later: **System Settings > Privacy & Security > Open Anyway**
   - macOS Catalina through Monterey: **System Preferences > Security & Privacy > General > Open Anyway**

Do not disable Gatekeeper globally. Managed Macs may prevent ad-hoc applications from being approved.

The release also contains a larger `Bundled-Encoder-Source.zip`. That archive is corresponding source code provided for FFmpeg/LAME license compliance; users do **not** need it. The smaller app ZIP already contains the Universal encoder helper required for M4A, MP3, and FLAC export.

## Compatibility

| Mac | Minimum system | Architecture |
| --- | --- | --- |
| Intel Mac | macOS Catalina 10.15 | `x86_64` |
| Apple silicon Mac | macOS Big Sur 11.0 | `arm64` |

Both architectures ship in one Universal app. Apple silicon begins with macOS Big Sur; there are no Apple silicon Macs that run Catalina.

## Features

### Import and Media

- Import MP3, WAV, M4A, AAC, FLAC, AIFF/AIF, and CAF audio
- Import MP4, MOV, M4V, MKV, and AVI as audio-only media when AVFoundation can decode the source
- Finder drag and drop, folder import, duplicate detection, search, filtering, sorting, renaming, and media information
- Asynchronous high-density waveform analysis with persistent versioned caches
- Reusable audio proxies for video-origin media
- Missing-media detection, individual relinking, and folder-based relinking

### Timeline and Editing

- Multiple reorderable and collapsible tracks with adjustable heights
- Clip move, trim, split, duplicate, ripple delete, nudge, rename, and color labels
- Multi-selection, marquee selection, grouped editing, clipboard operations, and Option-drag duplication
- Automatic track creation when media is dropped below existing tracks
- Snapping to grid, playhead, markers, and clip edges
- In/Out points, markers, loop playback, follow-playhead, zoom to fit, and smooth trackpad zoom
- Linear, equal-power, ease-in, and ease-out fades plus explicit crossfades
- Clip volume automation envelopes with editable keyframes
- Undo/redo, dirty-state indicators, save prompts, crash recovery, and context menus

### Playback and Mixing

- Multitrack playback from the current playhead with smooth seeking
- Clip gain, pan, fades, automation, track volume/pan, mute, solo, and master gain
- Per-track and master meters with clipping feedback
- Missing or failed media is never silently ignored: editing, playback, and export remain blocked until it is resolved

### Export

| Format | Backend |
| --- | --- |
| WAV, AIFF | Native offline renderer |
| M4A/AAC, MP3, FLAC | Bundled Universal FFmpeg/LAME helper |

Export supports the entire project or the current In/Out range, mono or stereo output, selectable sample rates, compressed bitrates, progress, cancellation, and clipping detection. MP3 uses LAME-compatible sample rates up to 48 kHz. Exported audio includes trims, fades, crossfades, automation, clip/track mix controls, mute/solo state, and master gain.

## Quick Start

1. Choose **File > Import Media** or drag files into the media bin.
2. Drag media onto the timeline. Drop below the last lane to create another track automatically.
3. Move or trim clips, then adjust clip and track controls in the inspector and track headers.
4. Press `Space` to play or pause.
5. Choose **File > Export** to render WAV, AIFF, M4A, MP3, or FLAC.
6. Save the editable project as a readable `.liau` file.

## Projects, Recovery, and Caches

`.liau` projects are readable JSON documents containing timeline structure, media references, mix settings, markers, view state, and automation. They do not embed source media, waveform arrays, or proxy audio.

- Relative media paths are saved when possible.
- **File > Collect Project Media** creates a portable project copy with a `Media/` folder.
- Recovery is offered only when a saved project had unsaved work and the previous session ended unexpectedly.
- Original source media is never modified by editing, normalization, proxy generation, or export.
- Export cannot overwrite imported source media or generated proxies.

Generated caches are stored under:

```text
~/Library/Application Support/LightAudio Editor/
|-- Media Proxies/
|-- Recovery/
`-- Waveforms/
```

**LightAudio Editor > Preferences > Clear App Cache** removes generated waveforms, proxy audio, and recovery snapshots. It does not remove `.liau` projects or original media.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `Space` | Play or pause |
| `Command-S` / `Command-O` | Save / open project |
| `Command-I` / `Command-E` | Import / export |
| `Command-Z` / `Shift-Command-Z` | Undo / redo |
| `Command-C` / `Command-X` / `Command-V` | Copy / cut / paste clips |
| `Command-D` | Duplicate selected clips |
| `Delete` | Delete selected clips or automation keyframe |
| `S` or `Command-B` | Toggle razor tool |
| `I` / `O` / `Option-X` | Set In / set Out / clear range |
| `L` / `M` / `N` | Toggle loop / add marker / toggle snapping |
| `Command-=` / `Command--` | Zoom in / out |
| `Option-Command-=` / `Option-Command--` | Increase / decrease track height |
| `Option-Left Arrow` / `Option-Right Arrow` | Previous / next clip edge |
| `Home` / `End` | Jump to project start / end |

## Build from Source

Requirements:

- A Mac running macOS 10.15 or later
- Xcode with a current macOS SDK and Swift 5 toolchain

```bash
git clone https://github.com/ythdzys/LightAudio-Editor.git
cd LightAudio-Editor
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  build
```

The app is produced at `Build/DerivedData/Build/Products/Debug/LightAudio Editor.app`. You can also open `LightAudio Editor.xcodeproj`, select the **LightAudio Editor** scheme, and run on **My Mac**.

Run the regression suite with:

```bash
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  test
```

The current suite contains 59 tests covering project validation, recovery, relinking, editing and undo behavior, automation, crossfades, rendering, export safety, cancellation, cache workflows, timeline invalidation, and real bundled M4A/MP3/FLAC exports.

## Repository Layout

```text
LightAudio Editor/       AppKit application source and resources
LightAudio EditorTests/  Regression test suite
Docs/                    Release, distribution, and branding documentation
Scripts/                 Universal build, encoder, and notarization tooling
ThirdParty/              Third-party source and license documentation
```

See [Contributing](CONTRIBUTING.md) before opening a pull request. Bug reports should use the [issue templates](https://github.com/ythdzys/LightAudio-Editor/issues/new/choose) and include the macOS version, Mac architecture, source format, exact steps, and any displayed error.

## Current Limitations

- No video preview or video editing
- No Audio Unit, VST, or other plug-in hosting
- Three-band EQ is a future-compatible project model and is not processed
- Normalize-on-export is not implemented
- The bundled encoder is limited to LightAudio Editor's AAC/M4A, MP3, and FLAC export workflow
- Public beta packages are currently ad-hoc signed and unnotarized

## Bundled Encoder and Licensing

LightAudio Editor includes FFmpeg 9.0.1 and LAME 4.0 as a separate, narrowly configured Universal command-line helper. It is not linked into the Swift executable. FFmpeg's GPL and nonfree configure options are disabled.

License notices and exact build metadata ship under `LightAudio Editor/Resources/BundledEncoder`. Reproducible build details are documented in [ThirdParty/FFmpeg/README.md](ThirdParty/FFmpeg/README.md), and every binary release includes a corresponding-source archive.

The LightAudio Editor application source does not currently declare an open-source license. Publication of the source does not grant rights beyond those provided by applicable law and GitHub's Terms of Service. Third-party components remain governed by their respective license files.
