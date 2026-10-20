<p align="center">
  <img src="LightAudio%20Editor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="LightAudio Editor app icon">
</p>

<h1 align="center">LightAudio Editor</h1>

<p align="center">
  <strong>English</strong> | <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  A lightweight, native multitrack audio editor for macOS.<br>
  Built with Swift, AppKit, AVFoundation, and AVFAudio.
</p>

<p align="center">
  <a href="https://github.com/ythdzys/LightAudio-Editor/releases/tag/v0.1.1-beta.4"><strong>Download Beta 4</strong></a>
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
  <a href="LICENSE"><img alt="PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-2f6f55"></a>
</p>

LightAudio Editor provides a timeline-oriented workflow for importing, arranging, trimming, mixing, and exporting audio. Video files are treated as audio-only sources: the app creates a reusable audio proxy and never presents video editing controls. All edits are non-destructive and original media is left untouched.

> [!IMPORTANT]
> LightAudio Editor is beta software. Keep backups of important `.liau` projects and source media. The current public build is ad-hoc signed and not notarized, so macOS requires one-time approval before first launch.

## Download and Install

1. Open the [Beta 4 release](https://github.com/ythdzys/LightAudio-Editor/releases/tag/v0.1.1-beta.4).
2. Download `LightAudio-Editor-0.1.1-beta-4-ADHOC-UNNOTARIZED.zip`.
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
- English and Simplified Chinese interface options in **LightAudio Editor > Preferences**
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
- Linear, equal-power, ease-in, and ease-out fades plus explicit crossfades; splits retain their original curves
- Clip volume automation envelopes, plus graph and numeric editors for clip pan and track volume automation
- Undo/redo, dirty-state indicators, save prompts, crash recovery, and context menus

### Playback and Mixing

- Multitrack playback from the current playhead with smooth seeking and continuous, sample-aligned looping
- Clip gain, pan, fades, automation, track volume/pan, mute, solo, and master gain
- Per-track and master meters with clipping feedback
- Missing or failed media is never silently ignored: editing, playback, and export remain blocked until it is resolved

### Export

| Format | Backend |
| --- | --- |
| WAV, AIFF | Native offline renderer |
| M4A/AAC, MP3, FLAC | Bundled Universal FFmpeg/LAME helper |

Export supports the entire project, the current In/Out range, or a custom numeric start/end range, mono or stereo output, selectable sample rates, compressed bitrates, progress, cancellation, and clipping detection. MP3 uses LAME-compatible sample rates up to 48 kHz. Exported audio includes trims, fades, crossfades, automation, clip/track mix controls, mute/solo state, and master gain.

To edit clip pan automation, use **Clip Pan Automation** in the inspector or the clip context menu. For track volume automation, right-click the track header and choose **Track Volume Automation**. Click the graph to add points, drag to move them, or use the point list and numeric fields. Edits support Undo/Redo and respect locked tracks.

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
- **File > Save As** creates and opens an independent project folder containing all library media, with a new project identity and fresh Undo history. Ordinary **Save** keeps the current document and references.
- Project formats 1–3 are supported on macOS and iPadOS. Files use the oldest required version: 2 for partial fades, 3 for partial crossfades, and 1 otherwise.
- **Decide Later** retains crash recovery for **Project > Recover Interrupted Project**. Failed restores keep the snapshot for retry; cache clearing is blocked while recovery is pending.
- M4A edit lists, gaps, retiming, and multiple audio tracks use the same container-aware preparation as video audio. Source verification and waveform/cache reads run in the background; waveform and proxy preparation share a two-job budget.
- Importing byte-identical media from another path reuses its existing library entry.
- **File > Collect Project Media** creates a portable project copy with a `Media/` folder, including unused library media.
- **Audio only for video files** is enabled by default when collecting a project. It replaces videos in the exported copy with lossless float PCM `.caf` audio, preserving native sample rate, channels, timing, and edits. Savings depend on the source; disable it to include original videos.
- Collection supports cancellation and removes incomplete output on failure. Move the entire collected folder to keep relative media links working.
- Relinking verifies complete file fingerprints and existing clip bounds. Older projects without a full fingerprint require manual confirmation; folder relinking only accepts unambiguous matches.
- Recovery is offered only when a saved project had unsaved work and an earlier session ended unexpectedly and its recovery remains unresolved.
- Original source media is never modified by editing, normalization, proxy generation, or export.
- Normalization supports cancellation and targets from −60 to 0 dBFS. Mono export folds down the panned stereo mix, including automation.
- Export cannot overwrite imported source media or generated proxies.

Generated caches are stored under:

```text
~/Library/Application Support/LightAudio Editor/
|-- Media Proxies/
|-- Recovery/
`-- Waveforms/
```

**LightAudio Editor > Preferences > Clear App Cache** removes generated waveforms, proxy audio, and recovery snapshots. It does not remove `.liau` projects or original media.

The interface follows the macOS language by default. Choose **English** or **Simplified Chinese** under **LightAudio Editor > Preferences > Language** to override it; the selected language is applied after restarting the app.

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

The regression suite covers portable audio-only/full-video collections, cancellation cleanup, decoded-sample comparisons, individual and recursive-folder relinking across supported media extensions, and project validation, localization, save prompts, recovery, relinking, editing and undo behavior, automation, crossfades, rendering, export safety, cancellation, cache workflows, timeline invalidation, and real bundled M4A/MP3/FLAC exports.

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

## License

Copyright 2026 Yishun Zhao. The first-party LightAudio Editor macOS source is available under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, study, modify, and redistribute it for permitted noncommercial purposes. Commercial use requires a separate written license from the copyright holder.

This is a **source-available noncommercial license**, not an OSI-approved open-source license. See [NOTICE](NOTICE) for the exact scope, branding restrictions, third-party exclusions, and explicit exclusion of any future iOS edition.

The LightAudio Editor name, logo, icon, and bundle identifier are not generally licensed for modified distributions. This keeps unofficial builds distinguishable from releases published by the project.

## Bundled Encoder Licensing

LightAudio Editor includes FFmpeg 9.0.1 and LAME 4.0 as a separate, narrowly configured Universal command-line helper. It is not linked into the Swift executable. FFmpeg's GPL and nonfree configure options are disabled.

License notices and exact build metadata ship under `LightAudio Editor/Resources/BundledEncoder`. Reproducible build details are documented in [ThirdParty/FFmpeg/README.md](ThirdParty/FFmpeg/README.md), and every binary release includes a corresponding-source archive. These third-party components remain governed by their own licenses and are not relicensed under PolyForm.
