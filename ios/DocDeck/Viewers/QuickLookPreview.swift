import QuickLook
import SwiftUI

/// SwiftUI wrapper around `QLPreviewController` for a single local file.
/// Quick Look natively renders PDF, office documents, plain text, markdown,
/// HTML, and images, so it is the single viewer used in this increment.
struct QuickLookPreview: UIViewControllerRepresentable {
    var url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            uiViewController.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
            super.init()
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
