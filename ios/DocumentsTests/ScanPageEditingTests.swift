import Foundation
import XCTest
@testable import Documents

final class ScanPageEditingTests: XCTestCase {
    func testReorderPreservesPageIdentityAndOrder() {
        let first = ScanPageBuffer(data: Data("1".utf8))
        let second = ScanPageBuffer(data: Data("2".utf8))
        let third = ScanPageBuffer(data: Data("3".utf8))

        let reordered = ScanPageEditing.reorder([first, second, third], from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(reordered.map(\.id), [second.id, third.id, first.id])

        let selected = ScanPageEditing.reorder(
            [first, second, third],
            from: IndexSet(integer: 0),
            to: 3,
            keepingSelectedPageID: first.id
        )
        XCTAssertEqual(selected.pages[selected.selectedIndex].id, first.id)
        XCTAssertEqual(selected.selectedIndex, 2)
    }

    func testRotateAndCropAreNondestructiveManifestEdits() {
        let originalData = Data("source bytes".utf8)
        let original = ScanPageBuffer(data: originalData)
        let rotated = ScanPageEditing.rotating(original)
        let cropped = ScanPageEditing.cropping(
            rotated,
            to: ScanCrop(x: -0.2, y: 0.1, width: 2, height: 0.7)
        )

        XCTAssertEqual(cropped.data, originalData)
        XCTAssertEqual(cropped.edit.rotationDegrees, 90)
        XCTAssertEqual(cropped.edit.crop, ScanCrop(x: 0, y: 0.1, width: 1, height: 0.7))
    }

    func testRotationWrapsAtFullTurnAndRemovalIsSafe() {
        var page = ScanPageBuffer(data: Data("page".utf8))
        for _ in 0..<5 { page = ScanPageEditing.rotating(page) }
        XCTAssertEqual(page.edit.rotationDegrees, 90)

        let pages = [page]
        XCTAssertTrue(ScanPageEditing.removing(pages, at: 7).count == 1)
        XCTAssertTrue(ScanPageEditing.removing(pages, at: 0).isEmpty)
    }

    func testRemovalKeepsSelectionOrChoosesDeterministicNeighbor() {
        let first = ScanPageBuffer(data: Data("1".utf8))
        let second = ScanPageBuffer(data: Data("2".utf8))
        let third = ScanPageBuffer(data: Data("3".utf8))

        let afterUnselectedRemoval = ScanPageEditing.removing(
            [first, second, third],
            at: 0,
            selectedPageID: third.id
        )
        XCTAssertEqual(afterUnselectedRemoval.selectedPageID, third.id)

        let afterSelectedFirst = ScanPageEditing.removing(
            [first, second, third],
            at: 0,
            selectedPageID: first.id
        )
        XCTAssertEqual(afterSelectedFirst.selectedPageID, second.id)

        let afterSelectedLast = ScanPageEditing.removing(
            [first, second, third],
            at: 2,
            selectedPageID: third.id
        )
        XCTAssertEqual(afterSelectedLast.selectedPageID, second.id)
    }

    func testCropGestureNormalizesCoordinatesInTheImageLocalSpace() {
        let crop = ScanPageEditing.crop(
            from: CGPoint(x: 20, y: 10),
            to: CGPoint(x: 120, y: 60),
            in: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(crop, ScanCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
    }
}
