#if DEBUG
import Foundation
import UIKit

/// Isolated launch fixture for scanner UI verification. It is enabled only by
/// a DEBUG launch argument and stores under a per-run Application Support
/// directory, so UI tests never read or overwrite a user's real draft.
enum ScanDraftUITestFixture {
    static let launchArgument = "-DocumentsScannerDraftFixtureID"

    static var identifier: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex]
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    static var directoryOverride: URL? {
        guard let identifier else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanDraftUITest-\(identifier)", isDirectory: true)
    }

    private static var seededMarkerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanDraftUITest-\(identifier).seeded", isDirectory: false)
    }

    static var isRequested: Bool {
        identifier != nil
    }

    /// Seeds two synthetic ID-card sides exactly once. The fixture is written
    /// through the production actor so the UI test exercises the same manifest
    /// and generation rules as a captured draft.
    static func seedIfNeeded() async {
        guard isRequested else { return }
        let store = ScanDraftStore.shared
        do {
            // Keep this marker outside the draft directory. A successful save
            // deliberately removes that directory, but a later UI-test
            // relaunch must not fabricate a new recovery prompt for the same
            // isolated fixture run.
            if let markerURL = seededMarkerURL,
               FileManager.default.fileExists(atPath: markerURL.path) {
                return
            }
            guard try await store.load() == nil else { return }
            let firstID = UUID()
            let secondID = UUID()
            let firstData = syntheticPage(label: "FRONT", color: .systemBlue)
            let secondData = syntheticPage(label: "BACK", color: .systemOrange)
            let draft = ScanDraft(
                mode: .idCard,
                pages: [
                    ScanDraftPage(id: firstID, fileName: "fixture-front.jpg"),
                    ScanDraftPage(id: secondID, fileName: "fixture-back.jpg"),
                ],
                revision: 1
            )
            let generation = await store.currentGeneration()
            try await store.save(
                draft,
                pageData: [firstID: firstData, secondID: secondData],
                generation: generation
            )
            if let markerURL = seededMarkerURL {
                try Data("seeded".utf8).write(to: markerURL, options: .atomic)
            }
        } catch {
            // The debug marker still appears so the UI test reports the
            // missing recovery prompt instead of hanging on an unbounded wait.
        }
    }

    private static func syntheticPage(label: String, color: UIColor) -> Data {
        let size = CGSize(width: 640, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 32, y: 32, width: 300, height: 72))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.black,
            ]
            (label as NSString).draw(at: CGPoint(x: 48, y: 48), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
#endif
