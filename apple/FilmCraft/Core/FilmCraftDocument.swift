import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import FilmCraftKit

extension UTType {
    /// `.fcproj`: the UTF-8 JSON envelope `{"format":"filmcraft.project",...}`. Exported by the app
    /// (Info.plist `UTExportedTypeDeclarations`, extension `fcproj`, conforms to `public.json`).
    static let filmcraftProject = UTType(exportedAs: "ca.hologram.filmcraft.project", conformingTo: .json)
}

/// A FilmCraft project as a document. The engine (`ProjectHandle`) owns the real state; the snapshot is its
/// project JSON, so autosave and "Duplicate / Share" work through the system document browser.
///
/// Not main-actor isolated: SwiftUI may call `init(configuration:)` and `snapshot` off the main thread. The
/// document holds the thread-safe engine handle and creates the main-actor `EditorModel` lazily on first use.
final class FilmCraftDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.filmcraftProject] }
    static var writableContentTypes: [UTType] { [.filmcraftProject] }

    let handle: ProjectHandle
    @MainActor private var cachedModel: EditorModel?

    @MainActor var model: EditorModel {
        if let cachedModel { return cachedModel }
        let created = EditorModel(handle: handle)
        cachedModel = created
        return created
    }

    /// A new untitled project (or the engine's procedural demo project with `-FilmCraftDemo`).
    init() {
        handle = AppEnvironment.isDemo ? ProjectHandle.demo() : ProjectHandle.newProject(name: "Untitled")
        Log.document.info("new document (demo: \(AppEnvironment.isDemo, privacy: .public))")
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            // Relative media paths resolve through the cache / Documents folders (see `EditorModel.bootstrap`).
            handle = try ProjectHandle.openJson(json: json, pathHint: nil)
        } catch {
            Log.document.error("open failed: \(errorText(error), privacy: .public)")
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: errorText(error)])
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        do {
            return Data(try handle.projectJson().utf8)
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: errorText(error)])
        }
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
