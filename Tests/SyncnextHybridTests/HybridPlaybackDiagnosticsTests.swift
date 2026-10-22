import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridPlaybackDiagnosticsTests: XCTestCase {
    func testProxySnapshotCarriesMediaMeasurementsOnTheSourceAxis() {
        let diagnostics = HybridPlaybackDiagnostics(
            sourceVideoWidth: 1_920,
            sourceVideoHeight: 1_080,
            averageBitrateMbps: 12.5,
            sourceVideoBitrate: 15_000_000,
            bufferedPosition: 225,
            sourceTime: 200
        )
        let snapshot = makeProxySnapshot(diagnostics: diagnostics)

        XCTAssertEqual(snapshot.diagnostics.videoSize, CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(snapshot.diagnostics.averageBitrateMbps, 12.5)
        XCTAssertEqual(snapshot.diagnostics.declaredVideoBitrateMbps, 15)
        XCTAssertEqual(snapshot.diagnostics.bitrateMbps, 12.5)
        XCTAssertEqual(snapshot.diagnostics.bufferSeconds, 25)
        // The proxy clock may be held at a different position during navigation.
        XCTAssertEqual(snapshot.currentTime, 50)
        XCTAssertEqual(snapshot.rate, 0)
        XCTAssertEqual(snapshot.phase, .paused)
    }

    func testMissingOrInvalidMeasurementsStayUnavailable() {
        let empty = HybridPlaybackDiagnostics()
        XCTAssertNil(empty.videoSize)
        XCTAssertNil(empty.averageBitrateMbps)
        XCTAssertNil(empty.declaredVideoBitrateMbps)
        XCTAssertNil(empty.bitrateMbps)
        XCTAssertNil(empty.bufferSeconds)

        for invalid in [Double.nan, .infinity, -.infinity] {
            let diagnostics = HybridPlaybackDiagnostics(
                sourceVideoWidth: 0,
                sourceVideoHeight: 0,
                averageBitrateMbps: invalid,
                bufferedPosition: invalid,
                sourceTime: 50
            )
            XCTAssertNil(diagnostics.videoSize)
            XCTAssertNil(diagnostics.averageBitrateMbps)
            XCTAssertNil(diagnostics.bufferSeconds)
        }
    }

    func testSourceSeekCannotProduceNegativeBufferDepth() {
        let diagnostics = HybridPlaybackDiagnostics(
            sourceVideoWidth: 1_920,
            sourceVideoHeight: 1_080,
            averageBitrateMbps: nil,
            bufferedPosition: 100,
            sourceTime: 200
        )
        XCTAssertEqual(diagnostics.bufferSeconds, 0)
        XCTAssertNil(diagnostics.averageBitrateMbps)
    }

    func testDeclaredRateIsDisplayedWhenPlaybackMeanIsUnavailable() {
        let diagnostics = HybridPlaybackDiagnostics(
            sourceVideoWidth: 3_840,
            sourceVideoHeight: 2_160,
            averageBitrateMbps: nil,
            sourceVideoBitrate: 56_902_286,
            bufferedPosition: 200,
            sourceTime: 200
        )
        XCTAssertEqual(diagnostics.declaredVideoBitrateMbps, 56.902286)
        XCTAssertNil(diagnostics.averageBitrateMbps)
        XCTAssertEqual(diagnostics.bitrateMbps, 56.902286)
        XCTAssertEqual(diagnostics.bufferSeconds, 0)
    }

    func testDiagnosticsUpdatesAreVisibleWhileTheProxyClockIsPaused() {
        let before = makeProxySnapshot(diagnostics: .init())
        let after = makeProxySnapshot(diagnostics: .init(
            videoSize: CGSize(width: 3_840, height: 2_160),
            averageBitrateMbps: 24,
            bufferSeconds: 60
        ))

        // Snapshot subscribers use removeDuplicates; media updates must reach
        // them even when the authoritative transport state has not changed.
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.currentTime, after.currentTime)
        XCTAssertEqual(before.phase, after.phase)
        XCTAssertEqual(before.route, after.route)
        XCTAssertEqual(before.rate, after.rate)
    }

    private func makeProxySnapshot(
        diagnostics: HybridPlaybackDiagnostics
    ) -> HybridPlaybackSnapshot {
        HybridPlaybackSnapshot(
            phase: .paused,
            route: .avKitProxy,
            currentTime: 50,
            duration: 600,
            rate: 0,
            selectedAudioTrackID: nil,
            selectedSubtitleTrackID: nil,
            audioTracks: [],
            subtitleTracks: [],
            diagnostics: diagnostics
        )
    }
}
