import Foundation

/// Imports every URL from a `fileImporter` result into the store.
/// Returns an error message if anything failed, or nil on full success.
@MainActor
func importPickerResult(_ result: Result<[URL], any Error>, store: DocumentStore) -> String? {
    switch result {
    case .success(let urls):
        var failures = 0
        for url in urls {
            do {
                try store.importFile(from: url)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            return "\(failures) of \(urls.count) file(s) could not be imported."
        }
        return nil
    case .failure(let error):
        return error.localizedDescription
    }
}
