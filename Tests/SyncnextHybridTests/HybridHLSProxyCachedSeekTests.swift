import XCTest
@testable import SyncnextHybrid

final class HybridHLSProxyCachedSeekTests: XCTestCase {
    func testCachedRepeatUnblocksClockWithoutInventingAResolvedSegment() {
        var authority = makeAuthority()
        let first = authority.seek(to: 37, uptime: 1)
        XCTAssertTrue(authority.acknowledgeSeekResponse(generation: first, uptime: 1))
        XCTAssertTrue(authority.recordResolvedSegment(37, requestGeneration: first, uptime: 1))

        let repeated = authority.seek(to: 37, uptime: 2)
        XCTAssertTrue(authority.acknowledgeSeekResponse(generation: repeated, uptime: 2))
        XCTAssertFalse(authority.recordResolvedSegment(39, requestGeneration: repeated, uptime: 2))
        XCTAssertFalse(canReleaseNextSegment(authority.snapshot(uptime: 2)))
        XCTAssertEqual(authority.snapshot(uptime: 12).currentTime, 37)

        XCTAssertTrue(authority.recordClientSeekLanding(
            generation: repeated, position: 37.125,
            loadedRanges: [37..<39.933], uptime: 12
        ))
        let landed = authority.snapshot(uptime: 12)
        XCTAssertEqual(landed.phase, .playing)
        XCTAssertEqual(landed.currentTime, 37) // Server clock, not client position.
        XCTAssertEqual(landed.resolvedSegmentIndices, []) // Cache caused no GET.
        let advanced = authority.snapshot(uptime: 22)
        XCTAssertEqual(advanced.currentTime, 47)
        XCTAssertTrue(canReleaseNextSegment(advanced))
    }

    func testCachedLandingAndEngineResponseAreBothRequiredInEitherOrder() {
        for clientFirst in [false, true] {
            var authority = makeAuthority()
            let generation = authority.seek(to: 23, uptime: 1)
            if clientFirst {
                XCTAssertTrue(authority.recordClientSeekLanding(
                    generation: generation, position: 23,
                    loadedRanges: [23..<25.933], uptime: 2
                ))
            } else {
                XCTAssertTrue(authority.acknowledgeSeekResponse(generation: generation, uptime: 2))
            }
            XCTAssertEqual(authority.snapshot(uptime: 5).phase, .waitingToPlay)
            XCTAssertEqual(authority.snapshot(uptime: 5).currentTime, 23)
            if clientFirst {
                XCTAssertTrue(authority.acknowledgeSeekResponse(generation: generation, uptime: 5))
            } else {
                XCTAssertTrue(authority.recordClientSeekLanding(
                    generation: generation, position: 23,
                    loadedRanges: [23..<25.933], uptime: 5
                ))
            }
            XCTAssertEqual(authority.snapshot(uptime: 15).currentTime, 33)
        }
    }

    func testStaleResponsesAndLandingsCannotCompleteSameTargetNewGeneration() {
        var authority = makeAuthority()
        let old = authority.seek(to: 23, uptime: 1)
        let current = authority.seek(to: 23, uptime: 2)
        XCTAssertFalse(authority.acknowledgeSeekResponse(generation: old, uptime: 3))
        XCTAssertFalse(authority.recordClientSeekLanding(
            generation: old, position: 23, loadedRanges: [23..<26], uptime: 3
        ))
        XCTAssertTrue(authority.acknowledgeSeekResponse(generation: current, uptime: 4))
        XCTAssertEqual(authority.snapshot(uptime: 5).phase, .waitingToPlay)
        XCTAssertTrue(authority.recordClientSeekLanding(
            generation: current, position: 23, loadedRanges: [23..<26], uptime: 5
        ))
        XCTAssertEqual(authority.snapshot(uptime: 6).currentTime, 24)
    }

    func testUnbufferedOrOffTargetClientPositionCannotConfirmLanding() {
        var authority = makeAuthority()
        let generation = authority.seek(to: 23, uptime: 1)
        XCTAssertTrue(authority.acknowledgeSeekResponse(generation: generation, uptime: 1))
        let invalid: [(Double, [Range<Double>])] = [
            (23, []), (23, [0..<3]), (20, [20..<26]), (.nan, [23..<26]),
        ]
        for (index, landing) in invalid.enumerated() {
            let (position, ranges) = landing
            let uptime = Double(2 + index * 2)
            XCTAssertFalse(authority.recordClientSeekLanding(
                generation: generation, position: position, loadedRanges: ranges, uptime: uptime
            ))
            XCTAssertEqual(authority.snapshot(uptime: uptime + 1).phase, .waitingToPlay)
            XCTAssertEqual(authority.snapshot(uptime: uptime + 1).currentTime, 23)
        }
    }

    func testCachedLandingPreservesPauseAndMaterialWaiting() {
        var authority = makeAuthority()
        authority.setRate(0, uptime: 1)
        let generation = authority.seek(to: 23, uptime: 1)
        authority.update(material: .init(phase: .waiting, bufferedThrough: 23), uptime: 1)
        XCTAssertTrue(authority.recordClientSeekLanding(
            generation: generation, position: 23, loadedRanges: [23..<26], uptime: 2
        ))
        XCTAssertTrue(authority.acknowledgeSeekResponse(generation: generation, uptime: 2))
        XCTAssertEqual(authority.snapshot(uptime: 5).phase, .paused)
        XCTAssertEqual(authority.snapshot(uptime: 5).rate, 0)
        authority.setRate(1, uptime: 5)
        XCTAssertEqual(authority.snapshot(uptime: 6).phase, .waitingToPlay)
        XCTAssertEqual(authority.snapshot(uptime: 6).currentTime, 23)
        authority.update(material: .init(phase: .flowing, bufferedThrough: 40), uptime: 6)
        XCTAssertEqual(authority.snapshot(uptime: 7).currentTime, 24)
    }

    func testLateClientLandingDoesNotReviveCompletedTail() {
        var authority = makeAuthority()
        let generation = authority.seek(to: 90, uptime: 1)
        XCTAssertTrue(authority.acknowledgeSeekResponse(generation: generation, uptime: 2))
        XCTAssertTrue(authority.completeSeek(generation: generation, uptime: 2))
        XCTAssertFalse(authority.recordClientSeekLanding(
            generation: generation, position: 89.5, loadedRanges: [89..<90], uptime: 3
        ))
        let ended = authority.snapshot(uptime: 10)
        XCTAssertEqual(ended.phase, .ended)
        XCTAssertEqual(ended.currentTime, 90)
        XCTAssertEqual(ended.rate, 0)
    }

    private func makeAuthority() -> HybridHLSTimelineAuthority {
        var authority = HybridHLSTimelineAuthority(duration: 90, initialPosition: 0, uptime: 0)
        authority.markReady(uptime: 0)
        authority.setRate(1, uptime: 0)
        return authority
    }

    private func canReleaseNextSegment(_ state: HybridHLSTimelineState) -> Bool {
        HybridHLSProxyReleasePolicy.canRelease(
            segmentStart: 40, authoritativePlayhead: state.currentTime,
            bufferedThrough: 49, duration: 90, lead: 3
        )
    }
}
