import SwiftUI

/// Shared localized copy for counts that appear in more than one document
/// surface. The inflection marker is understood by the string catalog, so
/// English keeps the singular and plural forms in one source of truth.
enum AppStrings {
    static func documentCount(_ count: Int) -> LocalizedStringKey {
        "^[\(count) document](inflect: true)"
    }

    static func totalDocumentCount(_ count: Int) -> LocalizedStringKey {
        "^[\(count) document](inflect: true) in total"
    }

    static func fileCount(_ count: Int) -> LocalizedStringKey {
        "^[\(count) file](inflect: true)"
    }

    static func selectedDocumentCount(_ count: Int) -> LocalizedStringKey {
        "^[\(count) document selected](inflect: true)"
    }

    static func documentCountString(_ count: Int) -> String {
        String(localized: "^[\(count) document](inflect: true)")
    }

    static func fileCountString(_ count: Int) -> String {
        String(localized: "^[\(count) file](inflect: true)")
    }
}
