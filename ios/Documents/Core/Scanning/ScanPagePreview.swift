import SwiftUI
import UIKit

/// Async, bounded rendering used by scanner surfaces. Keeping the source
/// bytes out of the SwiftUI body avoids decoding a camera-sized image during
/// every list or page transition.
struct ScanPagePreview: View {
    let page: ScanPageBuffer
    var maxDimension: CGFloat = 800

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: page.previewKey) {
            image = nil
            failed = false
            do {
                let data = try await ScanPageRenderer.previewData(for: page, maxDimension: maxDimension)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data)
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
