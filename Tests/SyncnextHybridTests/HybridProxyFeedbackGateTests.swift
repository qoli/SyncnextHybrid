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

    func testUnmatchedObservationDoesNotDiscardDelayedMirror() {
        let gate = HybridProxyFeedbackGate()

        gate.performMirroredRateChange(to: 0) {}

        XCTAssertTrue(gate.shouldForwardRateObservation(1))
        XCTAssertFalse(gate.shouldForwardRateObservation(0))
    }

    func testAutomaticPauseDuringMirroredSeekIsNotForwarded() {
        let gate = HybridProxyFeedbackGate()

        let token = gate.beginMirroredSeek()

        XCTAssertFalse(gate.shouldForwardRateObservation(0))
        gate.completeMirroredSeek(token)
        XCTAssertTrue(gate.shouldForwardRateObservation(0))
    }

    func testDecisionIdentifiesMatchedMirroredRate() {
        let gate = HybridProxyFeedbackGate()
        gate.performMirroredRateChange(to: 0) {}

        let decision = gate.rateObservationDecision(0)

        XCTAssertEqual(
            decision.disposition,
            .suppressMirroredRate
        )
        XCTAssertNotNil(decision.matchedMirroredRateAge)
        XCTAssertEqual(decision.pendingMirroredRateCount, 0)
        XCTAssertEqual(decision.activeMirroredSeekCount, 0)
    }

    func testDecisionIdentifiesActiveMirroredSeek() {
        let gate = HybridProxyFeedbackGate()
        let token = gate.beginMirroredSeek()

        let decision = gate.rateObservationDecision(0)

        XCTAssertEqual(
            decision.disposition,
            .suppressActiveSeek
        )
        XCTAssertNil(decision.matchedMirroredRateAge)
        XCTAssertEqual(decision.activeMirroredSeekCount, 1)
        gate.completeMirroredSeek(token)
    }
}
