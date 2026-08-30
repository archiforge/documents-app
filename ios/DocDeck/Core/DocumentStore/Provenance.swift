import Foundation

/// Where a document record came from. Drives the "Scanned" filter chip and
/// the per-row origin caption (Android: "From 'Scan document'").
enum Provenance: String, Codable, CaseIterable, Sendable {
    case imported
    case scanned
    case created
    case converted
    case device
    case cloud

    /// Row caption shown under the metadata line; nil hides the caption.
    var caption: String? {
        switch self {
        case .imported: nil
        case .scanned: "From ‘Scan document’"
        case .created: "Created in Documents"
        case .converted: "From converter"
        case .device: "On this device"
        case .cloud: "iCloud Drive"
        }
    }
}
