import XCTest
@testable import SyncnextHybrid

final class HybridSeekTargetPolicyTests: XCTestCase {
    func testPreReadyZeroDurationPreservesRequestedTarget() throws {
        XCTAssertEqual(
            try HybridSeekTargetPolicy.target(
                requested: 28.85,
                duration: 0
            ),
            28.85,
            accuracy: 0.000_001
        )
    }

    func testIndefiniteDurationPreservesRequestedTarget() throws {
        XCTAssertEqual(
            try HybridSeekTargetPolicy.target(
                requested: 28.85,
                duration: .infinity
            ),
            28.85,
            accuracy: 0.000_001
        )
    }

    func testKnownDurationClampsTargetToMediaEnd() throws {
        XCTAssertEqual(
            try HybridSeekTargetPolicy.target(
                requested: 1_500,
                duration: 1_420.074
            ),
            1_420.074,
            accuracy: 0.000_001
        )
    }

    func testNegativeTargetStillNormalizesToMediaStart() throws {
        XCTAssertEqual(
            try HybridSeekTargetPolicy.target(
                requested: -1,
                duration: 1_420.074
            ),
            0
        )
    }

    func testNonFiniteTargetFailsExplicitly() {
        XCTAssertThrowsError(
            try HybridSeekTargetPolicy.target(
                requested: .nan,
                duration: 1_420.074
            )
        ) { error in
            XCTAssertEqual(
                error as? HybridPlaybackError,
                .invalidSeekPosition
            )
        }
    }
}
