import XCTest
@testable import Documents

/// Phase 0 regression: `scanTrace` used to call itself unconditionally,
/// stack-overflowing on the very first trace — every scan success, cancel,
/// failure, and save on a physical device could crash. Reaching the end of
/// these tests proves the trace path terminates.
@MainActor
final class ScanTraceTests: XCTestCase {
    func testScanTraceTerminatesInsteadOfRecursing() {
        scanTrace("regression: trace must not recurse")
        scanTrace("second message")
        scanTrace("third message")
    }
}
