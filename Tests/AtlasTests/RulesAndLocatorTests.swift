import XCTest
@testable import Atlas

final class RulesAndLocatorTests: XCTestCase {

    // MARK: - BinaryLocator Tests

    func testBinaryLocatorFindsAndCachesBinary() {
        BinaryLocator.clearCache()
        
        let path = BinaryLocator.locate("sh")
        XCTAssertNotNil(path, "Expected to find 'sh' in system directories")
        
        // Second call should hit the cache
        let cachedPath = BinaryLocator.locate("sh")
        XCTAssertEqual(path, cachedPath)
        
        BinaryLocator.clearCache()
        let pathAfterClear = BinaryLocator.locate("sh")
        XCTAssertEqual(path, pathAfterClear)
    }

    func testBinaryLocatorNonExistentReturnsNil() {
        let nonExistent = BinaryLocator.locate("non_existent_binary_xyz_12345")
        XCTAssertNil(nonExistent)
    }

    // MARK: - RulesStore Tests

    @MainActor
    func testRulesStoreAddToggleDelete() {
        let store = RulesStore.shared
        let initialCount = store.rules.count
        
        let customRule = UserRule(
            trigger: "testpodcast",
            instruction: "Convert to MP3 320kbps",
            folderFilter: "Podcasts",
            isEnabled: true
        )
        
        store.add(rule: customRule)
        XCTAssertEqual(store.rules.count, initialCount + 1)
        
        // Active rule matching
        let matches = store.activeRules(for: "process this testpodcast file", currentFolder: "/Users/user/Podcasts")
        XCTAssertTrue(matches.contains(where: { $0.id == customRule.id }))
        
        // Folder mismatch
        let mismatchFolder = store.activeRules(for: "process this testpodcast file", currentFolder: "/Users/user/Documents")
        XCTAssertFalse(mismatchFolder.contains(where: { $0.id == customRule.id }))
        
        // Toggle rule off
        store.toggle(id: customRule.id)
        let matchesDisabled = store.activeRules(for: "process this testpodcast file", currentFolder: "/Users/user/Podcasts")
        XCTAssertFalse(matchesDisabled.contains(where: { $0.id == customRule.id }))
        
        // Delete rule
        store.delete(id: customRule.id)
        XCTAssertEqual(store.rules.count, initialCount)
    }
}
