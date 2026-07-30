import AVFAudio
import XCTest
@testable import SyncnextHybrid

final class HybridAudioContinuityTrackerTests: XCTestCase {
    func testFirstBufferAcceptsOneSampleTimestampRounding() {
        var tracker = HybridAudioContinuityTracker(
            requestedStartPosition: 0
        )

        XCTAssertFalse(
            tracker.consume(sourcePosition: 1, frameLength: 5_555)
        )
        XCTAssertFalse(
            tracker.consume(sourcePosition: 5_556, frameLength: 4_800)
        )
    }

    func testFirstBufferRejectsOffsetBeyondTimestampRounding() {
        var tracker = HybridAudioContinuityTracker(
            requestedStartPosition: 0
        )

        XCTAssertTrue(
            tracker.consume(sourcePosition: 2, frameLength: 5_555)
        )
    }

    func testLaterBufferStillRequiresExactContinuity() {
        var tracker = HybridAudioContinuityTracker(
            requestedStartPosition: 0
        )

        XCTAssertFalse(
            tracker.consume(sourcePosition: 1, frameLength: 5_555)
        )
        XCTAssertTrue(
            tracker.consume(sourcePosition: 5_557, frameLength: 4_800)
        )
    }
}
