import UIKit
import XCTest
@testable import Documents

final class ToolCapabilityTests: XCTestCase {
    @MainActor
    func testEveryCatalogToolUsesAnAvailableSystemSymbol() {
        for tool in ToolItem.all {
            XCTAssertNotNil(UIImage(systemName: tool.symbol), tool.title)
        }
    }

    func testGroupedBoardPreservesEveryExistingToolOnce() {
        let grouped = [ToolItem.scanHero]
            + ToolItem.quickTools
            + ToolItem.fileConversion
            + ToolItem.supportingTools
            + ToolItem.aiTools

        XCTAssertEqual(grouped.count, ToolItem.all.count)
        XCTAssertEqual(Set(grouped.map(\.id)).count, grouped.count)
        XCTAssertEqual(Set(grouped.map(\.id)), Set(ToolItem.all.map(\.id)))
    }

    func testFunctionalToolsAreAvailableAndDeferredServicesExplainWhy() {
        let availableTitles = [
            "New Document",
            "Scan Document",
            "Scan ID Card",
            "Test Paper",
            "PDF Tools",
            "Format Convert",
            "To PDF",
            "Compress",
            "Extract",
        ]
        for title in availableTitles {
            guard let tool = ToolItem.all.first(where: { $0.title == title }) else {
                XCTFail("Missing tool \(title)")
                continue
            }
            XCTAssertEqual(tool.capability, .available, title)
        }

        let officeTitles = ["To Word", "To Excel", "To PPT"]
        for title in officeTitles {
            let tool = ToolItem.all.first { $0.title == title }
            XCTAssertEqual(tool?.capability, .available, title)
            XCTAssertTrue(tool?.capability.isAvailable ?? false, title)
        }

        let aiKinds = Set(ToolItem.aiTools.compactMap { tool -> AIToolKind? in
            guard case .ai(let kind) = tool.kind else { return nil }
            return kind
        })
        XCTAssertEqual(aiKinds, Set(AIToolKind.allCases))
        for tool in ToolItem.aiTools {
            XCTAssertFalse(tool.capability.reason?.contains("Phase") ?? false, tool.title)
        }
        XCTAssertEqual(
            ToolItem.all.first { $0.title == "Document Translation" }?.capability,
            .available
        )
        XCTAssertEqual(
            ToolItem.all.first { $0.title == "Smart Extraction" }?.capability,
            .available
        )
    }
}
