import UIKit
import XCTest
@testable import Documents

/// App-icon quick actions: shortcut-type mapping and pending routing.
@MainActor
final class QuickActionRouterTests: XCTestCase {
    func testEveryDestinationHasTitleAndSymbol() {
        for destination in QuickActionRouter.Destination.allCases {
            XCTAssertFalse(destination.localizedTitle.isEmpty)
            XCTAssertFalse(destination.symbolName.isEmpty)
            XCTAssertFalse(
                UIImage(systemName: destination.symbolName) == nil,
                "\(destination.rawValue) needs a real SF Symbol"
            )
        }
    }

    func testShortcutTypeRoundTripsEveryDestination() {
        for destination in QuickActionRouter.Destination.allCases {
            let type = QuickActionRouter.shortcutTypePrefix + destination.rawValue
            XCTAssertEqual(QuickActionRouter.destination(forShortcutType: type), destination)
        }
    }

    func testUnknownShortcutTypesAreIgnored() {
        XCTAssertNil(QuickActionRouter.destination(forShortcutType: "com.other.app.action"))
        XCTAssertNil(QuickActionRouter.destination(forShortcutType: "com.docdeck.app.quickaction.nope"))
        XCTAssertNil(QuickActionRouter.destination(forShortcutType: ""))
    }

    func testConsumeShortcutSetsPending() {
        let router = QuickActionRouter()
        XCTAssertNil(router.pending)

        let item = UIApplicationShortcutItem(
            type: QuickActionRouter.shortcutTypePrefix + QuickActionRouter.Destination.scan.rawValue,
            localizedTitle: "Scan Document"
        )
        router.consumeShortcut(item)
        XCTAssertEqual(router.pending, .scan)

        router.pending = nil
        router.consumeShortcut(UIApplicationShortcutItem(type: "unrelated", localizedTitle: "x"))
        XCTAssertNil(router.pending)
    }

    func testConsumeStagedShortcutPicksUpAndClearsStagedItem() {
        QuickActionDelegate.stagedShortcutItem = UIApplicationShortcutItem(
            type: QuickActionRouter.shortcutTypePrefix + QuickActionRouter.Destination.importFiles.rawValue,
            localizedTitle: "Import Files"
        )
        let router = QuickActionRouter()
        router.consumeStagedShortcut()
        XCTAssertEqual(router.pending, .importFiles)
        XCTAssertNil(QuickActionDelegate.stagedShortcutItem)

        // Nothing staged: pending is left alone.
        router.pending = .scan
        router.consumeStagedShortcut()
        XCTAssertEqual(router.pending, .scan)
    }

    func testDelegateStagesShortcutAndPosts() {
        // The notification is the assertion: if the delegate drops it, the
        // wait times out. The staged static itself is not asserted here —
        // the running host app's HomeView also observes the notification
        // and legitimately consumes it first.
        let delegate = QuickActionDelegate()
        let expectation = expectation(forNotification: .quickActionShortcutReceived, object: nil)
        let item = UIApplicationShortcutItem(
            type: QuickActionRouter.shortcutTypePrefix + QuickActionRouter.Destination.newDocument.rawValue,
            localizedTitle: "New Text"
        )
        delegate.application(
            UIApplication.shared,
            performActionFor: item
        ) { _ in }
        wait(for: [expectation], timeout: 1)
        QuickActionDelegate.stagedShortcutItem = nil
    }

    func testEachDestinationRoutesToATab() {
        XCTAssertEqual(HomeView.tab(for: .scan), .tools)
        XCTAssertEqual(HomeView.tab(for: .newDocument), .tools)
        XCTAssertEqual(HomeView.tab(for: .importFiles), .recent)
    }
}
