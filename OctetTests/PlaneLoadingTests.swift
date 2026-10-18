import XCTest
@testable import Octet

@MainActor
final class PlaneLoadingTests: XCTestCase {
    func testEmptyFolderStaysLoadedDuringRefresh() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = FilesPlaneModel()
        model.load(folder.path)
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.loaded)
        try await finish(model)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.loaded)

        model.load(folder.path, force: true)
        XCTAssertTrue(model.loading)
        XCTAssertTrue(model.loaded, "An empty result must not become an initial-loading skeleton on refresh")
        try await finish(model)
    }

    func testChangingFolderClearsPreviousFilesWhileLoading() async throws {
        let first = try makeFolder(), second = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Data("hello".utf8).write(to: first.appendingPathComponent("hello.txt"))
        let model = FilesPlaneModel()
        model.load(first.path)
        try await finish(model)
        XCTAssertFalse(model.files.isEmpty)

        model.load(first.path, force: true)
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.files.isEmpty, "Refresh must retain existing content")
        try await finish(model)

        model.load(second.path)
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.tree.isEmpty)
        try await finish(model)
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.files.isEmpty)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func finish(_ model: FilesPlaneModel) async throws {
        for _ in 0..<200 {
            if !model.loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("File loading did not finish")
    }
}
