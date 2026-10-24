import Foundation
import Testing
@testable import FilmCraft

@Suite struct OwnedMediaTests {
    @Test func importCopiesSourceWithoutOverwritingAndReusesIdenticalBytes() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try Data("first".utf8).write(to: source)
        let first = try AppEnvironment.copyIntoOwnedMedia(source)
        defer { try? FileManager.default.removeItem(at: first) }
        #expect(first != source)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try AppEnvironment.copyIntoOwnedMedia(source) == first)

        try Data("second".utf8).write(to: source)
        let second = try AppEnvironment.copyIntoOwnedMedia(source)
        defer { try? FileManager.default.removeItem(at: second) }
        #expect(second != first)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
        #expect(try Data(contentsOf: source) == Data("second".utf8))
    }
}
