import Foundation

/// Pure state for the row-selection mode (board R3.8), shared by Recent and
/// Favorites. Kept free of UI so the transitions are unit-testable.
/// Select-all is scoped by the caller: the tab passes its visible records
/// (format chip + search in Recent), and rows selected under a narrower
/// scope stay selected when the scope widens again.
struct BulkSelection: Equatable {
    private(set) var isActive = false
    private(set) var selectedIDs: Set<UUID> = []

    var count: Int { selectedIDs.count }
    var isEmpty: Bool { selectedIDs.isEmpty }

    func contains(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }

    /// False for an empty scope so the select-all button never claims a
    /// fully-selected empty list.
    func allSelected(in ids: [UUID]) -> Bool {
        !ids.isEmpty && Set(ids).isSubset(of: selectedIDs)
    }

    mutating func enter() {
        isActive = true
        selectedIDs = []
    }

    mutating func exit() {
        isActive = false
        selectedIDs = []
    }

    mutating func toggle(_ id: UUID) {
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
    }

    /// Adds every id in the scope, keeping rows selected under other scopes.
    mutating func selectAll(_ ids: [UUID]) {
        selectedIDs.formUnion(ids)
    }

    mutating func deselectAll() {
        selectedIDs = []
    }

    /// Drops rows that left the tab's list (after a bulk trash or
    /// unfavorite) without leaving select mode.
    mutating func remove(_ ids: Set<UUID>) {
        selectedIDs.subtract(ids)
    }
}
