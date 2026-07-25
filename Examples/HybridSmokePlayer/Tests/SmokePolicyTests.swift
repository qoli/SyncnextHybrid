import AetherEngine
import XCTest
@testable import HybridSmokePlayer

final class SmokePolicyTests: XCTestCase {
    func testAetherVideoDimensionsPreferSourceMetadata() {
        let dimensions = AetherSmokeState.videoDimensions(
            sourceWidth: 720,
            sourceHeight: 480,
            nativePresentationWidth: 1920,
            nativePresentationHeight: 1080
        )

        XCTAssertEqual(dimensions.width, 720)
        XCTAssertEqual(dimensions.height, 480)
    }

    func testAetherVideoDimensionsUseNativePresentationFallback() {
        let dimensions = AetherSmokeState.videoDimensions(
            sourceWidth: 0,
            sourceHeight: 0,
            nativePresentationWidth: 1920,
            nativePresentationHeight: 1080
        )

        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testFiniteDurationMustContainSeekAndPostSeekBudget()
        throws
    {
        XCTAssertNoThrow(
            try SmokePolicy.validateDuration(
                300,
                seekSeconds: 150
            )
        )

        XCTAssertThrowsError(
            try SmokePolicy.validateDuration(
                12,
                seekSeconds: 10
            )
        ) { error in
            guard let failure = error as? SmokeFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .mediaTooShortForSeek = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNativePrerollIsValidButEarlierTimeFails() {
        XCTAssertNoThrow(
            try SmokePolicy.validateInitialTime(-0.083)
        )
        XCTAssertThrowsError(
            try SmokePolicy.validateInitialTime(-0.251)
        )
    }

    func testSeekLandingUsesExplicitTolerance() {
        XCTAssertNoThrow(
            try SmokePolicy.validateSeekLanding(
                target: 150,
                actual: 150.75
            )
        )
        XCTAssertThrowsError(
            try SmokePolicy.validateSeekLanding(
                target: 150,
                actual: 151.01
            )
        ) { error in
            guard let failure = error as? SmokeFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .seekLandingMismatch = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testProgressUsesAuthoritativeMediaTime() throws {
        XCTAssertEqual(
            try SmokePolicy.progress(from: -0.083, to: 2.0),
            2.083,
            accuracy: 0.0001
        )
        XCTAssertThrowsError(
            try SmokePolicy.progress(
                from: 0,
                to: .nan
            )
        )
    }

    func testAetherVideoGateAcceptsOnlyVideoBackends() {
        XCTAssertNoThrow(
            try AetherSmokeState.validateVideo(
                width: 1920,
                height: 1080,
                backend: .native
            )
        )
        XCTAssertNoThrow(
            try AetherSmokeState.validateVideo(
                width: 1920,
                height: 1080,
                backend: .software
            )
        )

        XCTAssertThrowsError(
            try AetherSmokeState.validateVideo(
                width: 1920,
                height: 1080,
                backend: .none
            )
        ) { error in
            XCTAssertEqual(
                (error as? SmokeFailure)?.code,
                "aether_backend_unavailable"
            )
        }
        XCTAssertThrowsError(
            try AetherSmokeState.validateVideo(
                width: 0,
                height: 0,
                backend: .audio
            )
        ) { error in
            XCTAssertEqual(
                (error as? SmokeFailure)?.code,
                "aether_video_required"
            )
        }
    }

    func testAetherPlaybackPhaseMappingPreservesFailures() {
        XCTAssertEqual(PlaybackPhase.paused.smokeName, "paused")
        XCTAssertEqual(
            PlaybackPhase.stalled(reconnecting: true).smokeName,
            "stalled"
        )
        XCTAssertEqual(
            PlaybackPhase.error("decode failed").smokeName,
            "failed"
        )
    }

    @MainActor
    func testAetherMetricsDoNotPretendToHaveHybridRoute() throws {
        let configuration = try SmokeConfiguration.interactive(
            mode: .aetherEngine,
            rawURL: "https://example.test/video.mkv",
            rawHeaders: "",
            rawSeekSeconds: "10"
        )
        let emitter = SmokeEventEmitter(
            configuration: configuration
        )
        let snapshot = AetherSmokeSnapshot(
            phase: .paused,
            currentTime: 0,
            duration: 300,
            requestedRate: 0,
            backend: .software,
            hasCurrentAVPlayer: false,
            videoWidth: 1920,
            videoHeight: 1080,
            audioTrackCount: 1,
            subtitleTrackCount: 0
        )

        let metrics = emitter.metrics(for: snapshot)

        XCTAssertEqual(metrics["mode"], "aetherEngine")
        XCTAssertEqual(metrics["route"], "not_applicable")
        XCTAssertEqual(metrics["aether_backend"], "software")
        XCTAssertEqual(
            metrics["aether_current_avplayer"],
            "absent"
        )
    }
}
