import XCTest
@testable import SyncnextHybrid

final class HybridProxyTransportIntentTests: XCTestCase {
    func testTwoMinuteNavigationDefersResumeUntilSeekCompletes()
        throws {
        var intent = HybridProxyTransportIntent()

        let navigation = try XCTUnwrap(
            intent.beginUserNavigation(
                from: 2,
                to: 122,
                duration: 300,
                resumeRate: 1
            )
        )

        XCTAssertEqual(navigation.distance, 120, accuracy: 0.001)
        XCTAssertFalse(intent.recordDesiredRate(1))
        XCTAssertEqual(
            intent.completeUserNavigation(navigation),
            1
        )
        XCTAssertFalse(intent.isNavigating)
    }

    func testPauseDuringLongNavigationWinsOverStaleResume()
        throws {
        var intent = HybridProxyTransportIntent()
        let navigation = try XCTUnwrap(
            intent.beginUserNavigation(
                from: 2,
                to: 122,
                duration: 300,
                resumeRate: 1
            )
        )

        XCTAssertFalse(intent.recordDesiredRate(0))
        XCTAssertEqual(
            intent.completeUserNavigation(navigation),
            0
        )
    }

    func testSupersededLongNavigationCannotCompleteNewestSeek()
        throws {
        var intent = HybridProxyTransportIntent()
        let first = try XCTUnwrap(
            intent.beginUserNavigation(
                from: 2,
                to: 122,
                duration: 300,
                resumeRate: 1
            )
        )
        let second = try XCTUnwrap(
            intent.beginUserNavigation(
                from: 122,
                to: 242,
                duration: 300,
                resumeRate: 1
            )
        )

        XCTAssertNil(intent.completeUserNavigation(first))
        XCTAssertEqual(
            intent.completeUserNavigation(second),
            1
        )
    }

    func testInvalidNavigationTimeFailsExplicitly() {
        var intent = HybridProxyTransportIntent()

        XCTAssertNil(
            intent.beginUserNavigation(
                from: 2,
                to: .nan,
                duration: 300,
                resumeRate: 1
            )
        )
        XCTAssertFalse(intent.isNavigating)
    }
}
