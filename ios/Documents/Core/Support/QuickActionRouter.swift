import Foundation
import Observation
import UIKit

/// Home-screen quick actions (the menu shown when long-pressing the app
/// icon). Registers the shortcut items with UIKit and routes a tapped
/// shortcut to the tab that fulfills it.
@MainActor
@Observable
final class QuickActionRouter {
    enum Destination: String, CaseIterable {
        case scan
        case importFiles
        case newDocument

        var localizedTitle: String {
            switch self {
            case .scan: "Scan Document"
            case .importFiles: "Import Files"
            case .newDocument: "New Text"
            }
        }

        var symbolName: String {
            switch self {
            case .scan: "doc.text.viewfinder"
            case .importFiles: "square.and.arrow.down"
            case .newDocument: "square.and.pencil"
            }
        }
    }

    /// Shortcut type prefix shared by every destination.
    static let shortcutTypePrefix = "com.docdeck.app.quickaction."

    /// The destination a tapped shortcut should open; nil when idle. Kept
    /// until the destination tab consumes it, so a tab that is instantiated
    /// by the selection change still sees it in `onAppear`.
    var pending: Destination?

    /// Registers the app-icon menu with UIKit.
    static func installShortcutItems() {
        UIApplication.shared.shortcutItems = Destination.allCases.map { destination in
            UIApplicationShortcutItem(
                type: shortcutTypePrefix + destination.rawValue,
                localizedTitle: destination.localizedTitle,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: destination.symbolName)
            )
        }
    }

    /// Maps a tapped shortcut's type back to a destination; unknown types
    /// (including shortcuts from other installed versions) are ignored.
    static func destination(forShortcutType type: String) -> Destination? {
        guard type.hasPrefix(shortcutTypePrefix) else { return nil }
        return Destination(rawValue: String(type.dropFirst(shortcutTypePrefix.count)))
    }

    /// Consumes a tapped shortcut item into `pending`.
    func consumeShortcut(_ item: UIApplicationShortcutItem) {
        pending = Self.destination(forShortcutType: item.type)
    }

    /// Picks up the shortcut the app was launched or re-opened from, if any.
    /// Call when the UI becomes active or the shortcut notification fires.
    func consumeStagedShortcut() {
        guard let item = QuickActionDelegate.stagedShortcutItem else { return }
        QuickActionDelegate.stagedShortcutItem = nil
        consumeShortcut(item)
    }
}

/// Bridges UIKit's quick-action delivery (there is no SwiftUI-scene API for
/// shortcut taps) into the router: `performActionFor` stages the tapped item
/// and posts, and the router picks it up when the UI can route it.
@MainActor
final class QuickActionDelegate: NSObject, UIApplicationDelegate {
    /// The shortcut the app was launched or re-opened from, awaiting routing.
    static var stagedShortcutItem: UIApplicationShortcutItem?

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Self.stagedShortcutItem = shortcutItem
        NotificationCenter.default.post(name: .quickActionShortcutReceived, object: nil)
        completionHandler(true)
    }
}

extension Notification.Name {
    /// Posted whenever UIKit hands over a tapped app-icon shortcut.
    static let quickActionShortcutReceived = Notification.Name("QuickActionShortcutReceived")
}
