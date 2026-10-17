@testable import AetherEngine
import XCTest
@testable import HybridSmokePlayer
@testable import SyncnextHybrid

final class SmokePolicyTests: XCTestCase {
    func testTailScenarioAdmitsOriginalTargetWithoutWeakeningOrdinarySmoke() {
        XCTAssertNoThrow(
            try SmokePolicy.validateTailTarget(
                duration: 1343.44,
                seekSeconds: 1343.34
            )
        )
        XCTAssertThrowsError(
            try SmokePolicy.validateDuration(1343.44, seekSeconds: 1343.34)
        )
        XCTAssertThrowsError(
            try SmokePolicy.validateTailTarget(duration: 1343.44, seekSeconds: 1314)
        )
    }

    func testClockAcceptanceRejectsTheOriginalHiddenRendererRewind() {
        XCTAssertThrowsError(
            try SmokePolicy.validateSynchronizedClocks(
                renderer: 0.08,
                server: 1343.34,
                client: 1343.00
            )
        )
        XCTAssertNoThrow(
            try SmokePolicy.validateSynchronizedClocks(
                renderer: 1343.44,
                server: 1343.44,
                client: 1343.34
            )
        )
        XCTAssertNoThrow(
            try SmokePolicy.validateSynchronizedClocks(
                renderer: 0.08,
                server: 0.08,
                client: 0.00
            )
        )
    }

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
            sourceTime: 0,
            bufferedPosition: 10,
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

@MainActor
final class HybridPlaybackEndNavigationTests: XCTestCase {
    func testSessionTailSeekParksRendererAndProxy() async throws {
        let (session, engine) = try await makeSession()
        defer { session.stop() }

        try await session.seek(to: 1_343.34)
        try await waitForClientSeek(session)

        XCTAssertEqual(engine.currentTime, 1_343.34, accuracy: 0.001)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(session.snapshot.phase, .paused)
        XCTAssertEqual(session.snapshot.rate, 0)
        XCTAssertEqual(session.snapshot.currentTime, 1_343.34, accuracy: 0.001)
        XCTAssertEqual(session.avPlayer.rate, 0)
        XCTAssertEqual(session.avPlayer.currentTime().seconds, 1_343.34, accuracy: 0.5)
    }

    func testSessionAutomaticTailSkipFinishesAndReplayMovesBothToZero() async throws {
        let (session, engine) = try await makeSession()
        defer { session.stop() }

        try await session.seek(to: 1_343.34, intent: .automaticSkip)
        try await waitForClientSeek(session)

        XCTAssertEqual(engine.currentTime, engine.duration, accuracy: 0.001)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(session.snapshot.phase, .ended)
        XCTAssertEqual(session.snapshot.rate, 0)
        let endedGeneration = try XCTUnwrap(session.hlsProxyServerObservation).seekGeneration

        try await session.replay()
        try await waitForClientSeek(session)

        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(engine.state, .playing)
        XCTAssertNotEqual(session.snapshot.phase, .ended)
        XCTAssertEqual(session.snapshot.rate, 1)
        XCTAssertLessThan(session.snapshot.currentTime, 1)
        XCTAssertLessThan(session.avPlayer.currentTime().seconds, 1)
        XCTAssertEqual(session.avPlayer.rate, 1)
        XCTAssertEqual(
            session.hlsProxyServerObservation?.seekGeneration,
            endedGeneration + 1
        )
    }

    func testSessionManualEndCanSeekBackWithoutPlaying() async throws {
        let (session, engine) = try await makeSession()
        defer { session.stop() }

        try await session.seek(to: 1_500)
        try await session.seek(to: 20)
        try await waitForClientSeek(session)

        XCTAssertEqual(engine.currentTime, 20, accuracy: 0.001)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(session.snapshot.phase, .paused)
        XCTAssertEqual(session.snapshot.currentTime, 20, accuracy: 0.001)
        XCTAssertEqual(session.snapshot.rate, 0)
        XCTAssertEqual(session.avPlayer.currentTime().seconds, 20, accuracy: 0.5)
        XCTAssertEqual(session.avPlayer.rate, 0)
    }

    func testNewSeekSupersedesQueuedReplay() async throws {
        let (session, engine) = try await makeSession()
        defer { session.stop() }
        try await session.seek(to: 1_343.34)
        try await waitForClientSeek(session)

        session.play()
        try await session.seek(to: 20)
        try await waitForClientSeek(session)

        XCTAssertEqual(engine.currentTime, 20, accuracy: 0.001)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(session.snapshot.currentTime, 20, accuracy: 0.001)
        XCTAssertEqual(session.snapshot.rate, 0)
    }

    func testPauseCancelsQueuedReplayAtEnd() async throws {
        let (session, engine) = try await makeSession()
        defer { session.stop() }
        try await session.seek(to: 1_343.34)
        try await waitForClientSeek(session)
        let generation = session.hlsProxyServerObservation?.seekGeneration

        session.play()
        session.pause()
        await Task.yield()

        XCTAssertEqual(engine.currentTime, 1_343.34, accuracy: 0.001)
        XCTAssertEqual(engine.state, .paused)
        XCTAssertEqual(session.snapshot.rate, 0)
        XCTAssertEqual(session.hlsProxyServerObservation?.seekGeneration, generation)
    }

    private func waitForClientSeek(_ session: HybridPlaybackSession) async throws {
        let generation = try XCTUnwrap(session.hlsProxyServerObservation).seekGeneration
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !session.hasAVKitProxyClientCompletedSeek(generation: generation),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(
            session.hasAVKitProxyClientCompletedSeek(generation: generation),
            "The real Proxy AVPlayer did not complete generation \(generation)"
        )
    }

    private func makeSession() async throws -> (HybridPlaybackSession, AetherEngine) {
        let engine = try AetherEngine()
        engine.duration = 1_343.44
        engine.clock.bufferedPosition = engine.duration
        engine.state = .playing
        let timeline = try await ProxyMediaFactory.makeTimeline(
            duration: engine.duration,
            initialPosition: 1_314,
            initialBufferedThrough: engine.duration
        )
        let session = HybridPlaybackSession(
            request: try HybridPlaybackRequest(url: URL(fileURLWithPath: "/tail-seek-fixture")),
            preparedEngine: engine,
            proxyTimeline: timeline
        )
        session.play()
        return (session, engine)
    }
}
