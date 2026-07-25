import XCTest
@testable import SyncnextHybrid

final class HybridProxyFeedbackGateTests: XCTestCase {
    func testDelayedMirroredRateObservationsAreNotForwarded() {
        let gate = HybridProxyFeedbackGate()

        gate.performMirroredRateChange(to: 0) {}
        gate.performMirroredRateChange(to: 1) {}

        XCTAssertFalse(gate.shouldForwardRateObservation(0))
        XCTAssertFalse(gate.shouldForwardRateObservation(1))
        XCTAssertTrue(gate.shouldForwardRateObservation(0))
    }

    func testCoalescedRateObservationConsumesOlderMirrors() {
        let gate = HybridProxyFeedbackGate()

        gate.performMirroredRateChange(to: 0) {}
        gate.performMirroredRateChange(to: 1) {}

        XCTAssertFalse(gate.shouldForwardRateObservation(1))
        XCTAssertFalse(gate.shouldForwardRateObservation(0))
        XCTAssertTrue(gate.shouldForwardRateObservation(0))
    }

    func testAutomaticPauseDuringMirroredSeekIsNotForwarded() {
        let gate = HybridProxyFeedbackGate()

        let token = gate.beginMirroredSeek(to: 10)

        XCTAssertFalse(gate.shouldForwardRateObservation(0))
        gate.completeMirroredSeek(token)
        XCTAssertTrue(gate.shouldForwardRateObservation(0))
    }

    func testMirroredTimeJumpIsConsumedByNotification() {
        let gate = HybridProxyFeedbackGate()

        let token = gate.beginMirroredSeek(to: 10)

        XCTAssertFalse(
            gate.shouldForwardTimeJump(
                to: 10.079,
                tolerance: 0.1
            )
        )
        gate.completeMirroredSeek(token)
        XCTAssertTrue(
            gate.shouldForwardTimeJump(
                to: 10.079,
                tolerance: 0.1
            )
        )
    }

    func testDifferentTimeJumpIsForwardedAndClearsMirror() {
        let gate = HybridProxyFeedbackGate()

        let token = gate.beginMirroredSeek(to: 10)

        XCTAssertTrue(
            gate.shouldForwardTimeJump(
                to: 40,
                tolerance: 0.1
            )
        )
        gate.completeMirroredSeek(token)
        XCTAssertTrue(
            gate.shouldForwardTimeJump(
                to: 10,
                tolerance: 0.1
            )
        )
    }
}
