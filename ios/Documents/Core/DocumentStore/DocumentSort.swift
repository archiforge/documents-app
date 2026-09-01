import Foundation

/// The Recent screen's sort control: which common field orders the list and
/// in which direction. Date orders by creation date (`importedAt`), so the
/// list reflects when documents were added, not when they were last opened.
/// Pure value logic mirroring `FormatFilter` so ordering is unit-testable
/// without SwiftData queries.
struct DocumentSort: Equatable, Sendable {
    /// Fields offered by the sort menu.
    enum Field: String, CaseIterable, Identifiable, Sendable {
        case date
        case name
        case size
        case kind

        var id: String { rawValue }

        var title: String {
            switch self {
            case .date: "Date"
            case .name: "Name"
            case .size: "Size"
            case .kind: "Type"
            }
        }
    }

    var field: Field = .date
    var isDescending: Bool = true

    /// The shipped default: newest first, matching the list's historical order.
    static let defaultSort = DocumentSort()

    /// Orders records by the field; equal keys tie-break on display name
    /// (A→Z) so the list stays deterministic regardless of fetch order.
    func sorted(_ records: [DocumentRecord]) -> [DocumentRecord] {
        records.sorted { less($0, $1) }
    }

    private func less(_ lhs: DocumentRecord, _ rhs: DocumentRecord) -> Bool {
        let primary: ComparisonResult
        switch field {
        case .date:
            primary = lhs.importedAt.compare(rhs.importedAt)
        case .name:
            primary = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        case .size:
            primary = compare(lhs.sizeBytes, rhs.sizeBytes)
        case .kind:
            primary = lhs.kind.label.localizedCaseInsensitiveCompare(rhs.kind.label)
        }
        if primary != .orderedSame {
            return isDescending ? primary == .orderedDescending : primary == .orderedAscending
        }
        let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if byName != .orderedSame {
            return byName == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func compare(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        if lhs < rhs { .orderedAscending }
        else if lhs > rhs { .orderedDescending }
        else { .orderedSame }
    }
}
