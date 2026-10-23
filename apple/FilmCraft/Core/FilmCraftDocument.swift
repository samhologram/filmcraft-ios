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
@MainActor
final class FilmCraftDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    nonisolated static var readableContentTypes: [UTType] { [.filmcraftProject] }
    nonisolated static var writableContentTypes: [UTType] { [.filmcraftProject] }

    let model: EditorModel

    /// A new untitled project (or the engine's procedural demo project with `-FilmCraftDemo`).
    init() {
        let handle = AppEnvironment.isDemo ? ProjectHandle.demo() : ProjectHandle.newProject(name: "Untitled")
        model = EditorModel(handle: handle)
        Log.document.info("new document (demo: \(AppEnvironment.isDemo, privacy: .public))")
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            // Relative media paths resolve through the cache / Documents folders (see `EditorModel.bootstrap`).
            model = EditorModel(handle: try ProjectHandle.openJson(json: json, pathHint: nil))
        } catch {
            Log.document.error("open failed: \(errorText(error), privacy: .public)")
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: errorText(error)])
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        do {
            return Data(try model.handle.projectJson().utf8)
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: errorText(error)])
        }
    }

    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
