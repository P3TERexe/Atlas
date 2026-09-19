import XCTest
@testable import Atlas

final class FinderContextProviderTests: XCTestCase {
    func testSnapshotPreservesCompletePathsAndSelectionOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(" cartella\nè ", isDirectory: true).path
        let selected = [
            root.appendingPathComponent(" sub \n").appendingPathComponent(" nome\nè %23.txt ").path,
            root.appendingPathComponent("secondo.txt").path
        ]
        let json = try JSONSerialization.data(withJSONObject: ["directory": directory, "selected": selected])
        let snapshot = try FinderContextProvider.decodeSnapshot(String(decoding: json, as: UTF8.self) + "\n")

        XCTAssertEqual(snapshot.directory.path, directory)
        XCTAssertEqual(snapshot.selected.map(\.path), selected)
    }

    func testInvalidSnapshotNeverBecomesAnEmptySelectionOrFallbackDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let invalidSnapshots: [[String: Any]] = [
            ["directory": root],
            ["directory": root, "selected": NSNull()],
            ["directory": root, "selected": "file.txt"],
            ["directory": root, "selected": [7]],
            ["directory": root, "selected": ["relative.txt"]],
            ["directory": "", "selected": []],
            ["directory": "relative", "selected": []]
        ]
        for object in invalidSnapshots {
            let json = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try FinderContextProvider.decodeSnapshot(String(decoding: json, as: UTF8.self))) {
                XCTAssertTrue($0 is FinderContextProvider.ContextError)
            }
        }
        XCTAssertThrowsError(try FinderContextProvider.decodeSnapshot("not JSON"))
    }
}
