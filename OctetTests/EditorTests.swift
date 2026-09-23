import XCTest
@testable import Octet

final class EditorTests: XCTestCase {
    func testRendererUsesHighContrastDefaultTextAndEnablesLinks() {
        var dark = OctetSettings()
        dark.themeName = "Dark"
        XCTAssertTrue(dark.rendererConfig.contains("foreground = ffffff"))
        XCTAssertTrue(dark.rendererConfig.contains("link-url = true"))

        var light = OctetSettings()
        light.themeName = "Light"
        XCTAssertTrue(light.rendererConfig.contains("foreground = 000000"))
    }

    @MainActor
    func testDocumentTracksAndSavesEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.swift")
        try "let answer = 41\n".write(to: file, atomically: true, encoding: .utf8)

        let document = try EditorDocument(url: file)
        XCTAssertFalse(document.isDirty)
        document.replaceText("let answer = 42\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(document.save())
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let answer = 42\n")
    }

    @MainActor
    func testRegistrySharesCanonicalBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)

        let first = try EditorBufferRegistry.shared.document(at: file)
        let second = try EditorBufferRegistry.shared.document(at: directory.appendingPathComponent("./shared.txt"))
        XCTAssertTrue(first === second)
    }

    @MainActor
    func testEditorPresentationTracksItsOpeningContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("context.swift")
        try "let context = true\n".write(to: file, atomically: true, encoding: .utf8)

        let workspace = EditorWorkspace()
        workspace.open(file, presentation: .split)
        XCTAssertEqual(workspace.presentation, .split)
        workspace.open(file, presentation: .full)
        XCTAssertEqual(workspace.presentation, .full)
        workspace.togglePresentation()
        XCTAssertEqual(workspace.presentation, .split)
    }

    func testFileIndexSkipsGeneratedAndHiddenTrees() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "source".write(to: directory.appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)
        try "generated".write(to: directory.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)

        let indexed = EditorFileIndex.files(in: directory.path).map(\.relativePath)
        XCTAssertTrue(indexed.contains("Sources/main.swift"))
        XCTAssertFalse(indexed.contains { $0.contains("node_modules") })
    }
}
