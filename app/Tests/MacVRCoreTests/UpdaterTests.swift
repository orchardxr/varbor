@testable import MacVRCore
import XCTest

final class UpdaterTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("0.0.2", than: "0.0.1"))
        XCTAssertTrue(Updater.isNewer("0.1", than: "0.0.9"))
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "0.10.10"))
        XCTAssertTrue(Updater.isNewer("0.0.10", than: "0.0.9"))
        XCTAssertFalse(Updater.isNewer("0.0.1", than: "0.0.1"))
        XCTAssertFalse(Updater.isNewer("0.0.1", than: "0.0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.0.1", than: "0.0.2"))
    }
}
