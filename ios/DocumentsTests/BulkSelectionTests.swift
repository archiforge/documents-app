import XCTest
@testable import Documents

/// Pure state machine of the selection mode (board R3.8): scoped
/// select-all, toggle, pruning after bulk actions, and enter/exit cleanup.
final class BulkSelectionTests: XCTestCase {
    func testEnterActivatesAndClearsPreviousState() {
        var selection = BulkSelection()
        selection.toggle(UUID())

        selection.enter()

        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)
    }

    func testExitDeactivatesAndClearsSelection() {
        var selection = BulkSelection()
        selection.enter()
        selection.toggle(UUID())

        selection.exit()

        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    func testToggleAddsThenRemoves() {
        let id = UUID()
        var selection = BulkSelection()

        selection.toggle(id)
        XCTAssertTrue(selection.contains(id))
        XCTAssertEqual(selection.count, 1)
        XCTAssertFalse(selection.isEmpty)

        selection.toggle(id)
        XCTAssertFalse(selection.contains(id))
        XCTAssertEqual(selection.count, 0)
    }

    func testSelectAllAddsScopeAndKeepsRowsSelectedUnderOtherScopes() {
        let hidden = UUID()
        var selection = BulkSelection()
        selection.enter()
        selection.toggle(hidden)

        let visible = [UUID(), UUID()]
        selection.selectAll(visible)

        XCTAssertEqual(selection.count, 3)
        XCTAssertTrue(visible.allSatisfy { selection.contains($0) })
        XCTAssertTrue(selection.contains(hidden))
    }

    func testAllSelectedRequiresNonEmptyFullyContainedScope() {
        var selection = BulkSelection()
        let a = UUID()
        let b = UUID()

        XCTAssertFalse(selection.allSelected(in: []), "An empty scope is never all-selected")
        XCTAssertFalse(selection.allSelected(in: [a, b]))

        selection.selectAll([a])
        XCTAssertFalse(selection.allSelected(in: [a, b]))

        selection.selectAll([b])
        XCTAssertTrue(selection.allSelected(in: [a, b]))
    }

    func testDeselectAllClearsSelectionWithoutLeavingSelectionMode() {
        var selection = BulkSelection()
        selection.enter()
        selection.selectAll([UUID(), UUID()])

        selection.deselectAll()

        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    func testRemovePrunesRowsWithoutLeavingSelectionMode() {
        let kept = UUID()
        let trashed = UUID()
        var selection = BulkSelection()
        selection.enter()
        selection.selectAll([kept, trashed])

        selection.remove([trashed])

        XCTAssertTrue(selection.isActive)
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(kept))
        XCTAssertFalse(selection.contains(trashed))
    }
}
