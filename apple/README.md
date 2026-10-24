# FilmCraft for iPad and iPhone

Native SwiftUI app on the unchanged FilmCraft Rust engine (UniFFI bridge in `bridge/`). Fork rules: `../FORK.md`.
Contracts between the bridge, the Swift core and the Swift UI: `docs/CONTRACT.md`.

## UX direction

Apple's Human Interface Guidelines first (system components, Liquid Glass materials, Dynamic Type, keyboard and
pointer, dark and light). Faithful to the desktop app's mental model: the same panels (Project, Source, Program,
Timeline, Effects, Effect Controls, Essential Graphics, Lumetri Color, Audio mixers…), the same timeline tools
(Selection, Ripple, Rolling, Razor, Slip, Slide, Rate Stretch, Pen, Hand, Zoom, Type…) and the same menu structure
(File, Edit, Clip, Sequence, Markers, Graphics and Titles, View, Window, Help).

**Reference app: LumaFusion** (the most-recommended multitrack video editor on the iPad App Store and the closest to a
desktop NLE), with **Final Cut Pro for iPad** as the secondary reference for touch gestures. Behaviour and look
only, clean-room: no assets, icons or code from either; icons are SF Symbols.

Conventions taken from them:

1. **Three zones on iPad**: media/panels top-leading, the viewer (Program monitor) top-trailing, the multitrack
   timeline across the full width at the bottom. The divider between top and bottom is draggable.
2. **Fixed centre playhead**: the timeline scrolls under a playhead fixed in the middle; dragging the timeline
   scrubs. Pinch horizontally to zoom the timeline.
3. **Media browser shows Photos directly** (albums, all videos, photos); tap a thumbnail to preview, tap "+" (or drag
   onto the timeline) to insert at the playhead. Nothing is "imported" first.
4. **Tap selects a clip, double-tap opens its editor** (Effect Controls inspector: transform, opacity, speed, volume,
   colour). Selected clips show trim handles at both ends.
5. **Edit bar under the viewer**: split at playhead (razor), delete, ripple delete, undo/redo, add marker, tool menu.
6. **Transport**: play/pause, frame step, go to start/end, timecode readout above the timeline.
7. **iPhone**: viewer on top, timeline below, a bottom tool strip; panels open as sheets with detents that keep the
   viewer visible.
8. **Share button** (top trailing) exports a movie to Photos or Files with resolution and quality options and a
   progress sheet.
9. **Hardware keyboard**: desktop shortcuts (J/K/L, space, V/C/B…) via hidden key-command buttons; pointer hover
   on clips and handles.
10. **Projects are documents** in the system document browser (open, rename, duplicate, share `.fcproj`).

Panels follow the Premiere model (CONTRACT §6): every desktop panel exists, opens from the panel menu and the Window
menu, and can be added, hidden, collapsed and stacked/reordered on iPad (arrangement persisted); panel-owned actions
sit in the panel header; the iPad menu bar merges the desktop menus into the iPadOS system groups in desktop order.

Per-idiom degradation (iPad windows are resizable): three zones + inspector column → inspector as a sheet below
~900 pt → iPhone layout (tool strip + sheets) in compact width. Nothing falls off screen: tool strips scroll as the
last resort.

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer PATH="$HOME/.cargo/bin:$PATH"
apple/scripts/build-xcframework.sh --sim-only --debug
cd apple && xcodegen generate
xcodebuild build-for-testing -scheme FilmCraft -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO -derivedDataPath build/dd
```

Gates before every commit: `cd apple/bridge && cargo test && cargo clippy --all-targets -- -D warnings`,
`apple/scripts/check-command-ids.sh`, `apple/scripts/tool-coverage.sh`, `apple/scripts/feature-coverage.sh --check`.

Demo: launch with `-FilmCraftDemo`: a new document opens with the engine's procedural demo project.
