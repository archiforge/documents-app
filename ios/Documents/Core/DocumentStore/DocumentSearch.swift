import Foundation

/// The Recent search bar: the query is a case- and diacritic-insensitive
/// substring of the document's display name. The active format chip is
/// applied first at the call site, so a search only narrows within the
/// chosen document type.
enum DocumentSearch {
    /// Whether `name` matches `query`. An empty or whitespace-only query
    /// matches everything (search inactive).
    static func matches(_ query: String, name: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
