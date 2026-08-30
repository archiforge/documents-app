import UIKit

/// Thin wrapper around the system print dialog for PDF payloads.
@MainActor
enum PDFPrinter {
    static func print(data: Data, jobName: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        info.orientation = .portrait

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data as NSData
        controller.present(animated: true)
    }
}
