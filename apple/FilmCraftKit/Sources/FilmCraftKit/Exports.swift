// Re-exports nothing by itself: the UniFFI-generated `filmcraft_apple.swift` (produced by
// apple/scripts/build-xcframework.sh) is compiled into this module, so `import FilmCraftKit`
// exposes ProjectHandle, CommandInfo, ProjectState, MediaInfo, etc.
// This file keeps the source directory present before the first bridge build.
@_exported import Foundation
