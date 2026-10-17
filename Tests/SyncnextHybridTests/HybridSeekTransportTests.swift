import XCTest
@testable import AetherEngine
@testable import SyncnextHybrid

final class HybridSeekEndPolicyTests: XCTestCase {
    func testEndBoundaryMatchesPinnedAetherContract() {
        for time in [0, 1_342.93, 1_342.94, 1_343.34, 1_343.44, 1_500] {
            XCTAssertEqual(
                HybridSeekEndPolicy.isAtEnd(
                    time: time, duration: 1_343.44, isLive: false
                ),
                AetherEngine.isAtEndOfMedia(
                    currentTime: time, duration: 1_343.44, isLive: false
                ),
                "time=\(time)"
            )
        }
    }

    func testOnlyAutomaticTailSkipNormalizesToExactEnd() throws {
        XCTAssertEqual(
            try HybridSeekEndPolicy.target(
                requested: 1_343.34, duration: 1_343.44,
                isLive: false, intent: .automaticSkip
            ),
            1_343.44
        )
        XCTAssertEqual(
            try HybridSeekEndPolicy.target(
                requested: 1_343.34, duration: 1_343.44,
                isLive: false, intent: .position
            ),
            1_343.34
        )
        XCTAssertEqual(
            try HybridSeekEndPolicy.target(
                requested: 59.7, duration: 1_343.44,
                isLive: false, intent: .automaticSkip
            ),
            59.7
        )
    }

    func testLiveAndUnknownDurationNeverBecomeTailCompletion() {
        for (duration, isLive) in [(0.0, false), (100.0, true), (.infinity, false)] {
            XCTAssertEqual(
                HybridSeekEndPolicy.disposition(
                    target: 100, duration: duration,
                    isLive: isLive, intent: .automaticSkip
                ),
                .none
            )
        }
    }
}

@MainActor
final class HybridSeekTransportTests: XCTestCase {
    func testLogReproductionParksBothClocksWithoutEngineReplay() async throws {
        let engine = RecordingSeekEngine()
        let timeline = SeekTimeline()
        let generation = timeline.begin(to: 1_343.34)

        try await HybridSeekTransport.perform(
            engine: engine, target: 1_343.34, intent: .position,
            isCurrent: { timeline.isCurrent(generation) },
            acceptLanding: { timeline.accept($0, generation: generation) }
        )

        XCTAssertEqual(engine.currentTime, 1_343.34)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(timeline.state.currentTime, 1_343.34)
        XCTAssertEqual(timeline.state.phase, .paused)
        XCTAssertEqual(timeline.state.rate, 0)
    }

    func testExactAndOutOfRangeEndSeeksNeverReplay() async throws {
        for requested in [1_343.44, 1_500.0] {
            let engine = RecordingSeekEngine()
            let timeline = SeekTimeline()
            let target = try HybridSeekEndPolicy.target(
                requested: requested, duration: engine.duration,
                isLive: false, intent: .position
            )
            let generation = timeline.begin(to: target)
            try await HybridSeekTransport.perform(
                engine: engine, target: target, intent: .position,
                isCurrent: { timeline.isCurrent(generation) },
                acceptLanding: { timeline.accept($0, generation: generation) }
            )

            XCTAssertEqual(engine.currentTime, engine.duration)
            XCTAssertEqual(engine.playCount, 0)
            XCTAssertEqual(timeline.state.phase, .paused)
        }
    }

    func testMeasuredTailLandingDoesNotTurnMidstreamResumeIntoReplay() async throws {
        let engine = RecordingSeekEngine()
        engine.landingOffset = 0.2
        let timeline = SeekTimeline()
        let generation = timeline.begin(to: 1_342.84)
        let result = try await HybridSeekTransport.perform(
            engine: engine, target: 1_342.84, intent: .automaticSkip,
            isCurrent: { timeline.isCurrent(generation) },
            acceptLanding: { timeline.accept($0, generation: generation) }
        )

        XCTAssertEqual(result, .parked)
        XCTAssertEqual(engine.currentTime, 1_343.04, accuracy: 0.001)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(timeline.state.phase, .paused)
    }

    func testAutomaticTailSkipCompletesAuthorityInsteadOfReplaying() async throws {
        let engine = RecordingSeekEngine()
        let timeline = SeekTimeline()
        let target = try HybridSeekEndPolicy.target(
            requested: 1_343.34, duration: engine.duration,
            isLive: false, intent: .automaticSkip
        )
        let generation = timeline.begin(to: target)
        try await HybridSeekTransport.perform(
            engine: engine, target: target, intent: .automaticSkip,
            isCurrent: { timeline.isCurrent(generation) },
            acceptLanding: { timeline.accept($0, generation: generation) }
        )

        XCTAssertEqual(engine.currentTime, engine.duration)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(timeline.state.phase, .ended)
        XCTAssertEqual(timeline.state.currentTime, engine.duration)
        XCTAssertEqual(timeline.state.rate, 0)
    }

    func testMidstreamSkipRestoresPlaybackAndSelectedSpeed() async throws {
        let engine = RecordingSeekEngine()
        let timeline = SeekTimeline(rate: 1.5)
        let generation = timeline.begin(to: 59.7)
        try await HybridSeekTransport.perform(
            engine: engine, target: 59.7, intent: .automaticSkip,
            isCurrent: { timeline.isCurrent(generation) },
            acceptLanding: { timeline.accept($0, generation: generation) }
        )

        XCTAssertEqual(engine.commands, [.seek(59.7), .rate(1.5), .play])
        XCTAssertEqual(engine.currentTime, 59.7)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(timeline.state.phase, .playing)
    }

    func testPausedEndRemainsSeekableBackwards() async throws {
        let engine = RecordingSeekEngine()
        let timeline = SeekTimeline(rate: 0)
        for target in [1_343.34, 20.0] {
            let generation = timeline.begin(to: target)
            try await HybridSeekTransport.perform(
                engine: engine, target: target, intent: .position,
                isCurrent: { timeline.isCurrent(generation) },
                acceptLanding: { timeline.accept($0, generation: generation) }
            )
        }

        XCTAssertEqual(engine.currentTime, 20)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(timeline.state.currentTime, 20)
        XCTAssertEqual(timeline.state.phase, .paused)
    }

    func testReplaySeeksBothClocksToZeroBeforePlay() async throws {
        let engine = RecordingSeekEngine()
        let timeline = SeekTimeline()
        let tail = timeline.begin(to: engine.duration)
        try await HybridSeekTransport.perform(
            engine: engine, target: engine.duration, intent: .automaticSkip,
            isCurrent: { timeline.isCurrent(tail) },
            acceptLanding: { timeline.accept($0, generation: tail) }
        )
        let replay = timeline.begin(to: 0)
        timeline.setRate(1.5)
        engine.commands.removeAll()
        try await HybridSeekTransport.perform(
            engine: engine, target: 0, intent: .position,
            isCurrent: { timeline.isCurrent(replay) },
            acceptLanding: { timeline.accept($0, generation: replay) }
        )

        XCTAssertEqual(engine.commands, [.seek(0), .rate(1.5), .play])
        XCTAssertEqual(engine.currentTime, 0)
        XCTAssertEqual(timeline.state.currentTime, 0)
        XCTAssertEqual(timeline.state.phase, .playing)
        XCTAssertEqual(timeline.state.seekGeneration, tail + 1)
    }

    func testPauseDuringReplayWinsOverOriginalPlayIntent() async throws {
        let engine = RecordingSeekEngine()
        engine.suspendSeeks = true
        let timeline = SeekTimeline()
        let generation = timeline.begin(to: 0)
        var starts = engine.seekStarts.makeAsyncIterator()
        let operation = Task {
            try await HybridSeekTransport.perform(
                engine: engine, target: 0, intent: .position,
                isCurrent: { timeline.isCurrent(generation) },
                acceptLanding: { timeline.accept($0, generation: generation) }
            )
        }
        _ = await starts.next()
        timeline.setRate(0)
        engine.finishSeek(to: 0)
        _ = try await operation.value

        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(timeline.state.phase, .paused)
    }

    func testOlderTailResponseCannotFinishNewerMidstreamSeek() async throws {
        let engine = RecordingSeekEngine()
        engine.suspendSeeks = true
        let timeline = SeekTimeline()
        var starts = engine.seekStarts.makeAsyncIterator()
        let firstGeneration = timeline.begin(to: engine.duration)
        let first = Task {
            try await HybridSeekTransport.perform(
                engine: engine, target: engine.duration, intent: .automaticSkip,
                isCurrent: { timeline.isCurrent(firstGeneration) },
                acceptLanding: { timeline.accept($0, generation: firstGeneration) }
            )
        }
        _ = await starts.next()
        let secondGeneration = timeline.begin(to: 20)
        let second = Task {
            try await HybridSeekTransport.perform(
                engine: engine, target: 20, intent: .position,
                isCurrent: { timeline.isCurrent(secondGeneration) },
                acceptLanding: { timeline.accept($0, generation: secondGeneration) }
            )
        }
        _ = await starts.next()
        engine.finishSeek(to: 20)
        _ = try await second.value
        engine.finishSeek(to: engine.duration)
        let stale = try await first.value

        XCTAssertNil(stale)
        XCTAssertEqual(engine.currentTime, 20)
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(timeline.state.phase, .playing)
        XCTAssertEqual(timeline.state.currentTime, 20)
        XCTAssertFalse(timeline.authority.completeSeek(generation: firstGeneration, uptime: 0))
    }

    func testTerminalRendererIsReopenedBeforeExplicitReplay() async throws {
        let engine = RecordingSeekEngine()
        engine.hybridHasEnded = true
        try await HybridSeekTransport.perform(
            engine: engine, target: 0, intent: .position,
            isCurrent: { true }, acceptLanding: { _ in .restoreRate(1) }
        )

        XCTAssertEqual(engine.commands, [.reload, .seek(0), .rate(1), .play])
    }

    func testReplayReloadFailureIsReportedWithoutSeekOrPlay() async {
        let engine = RecordingSeekEngine()
        engine.hybridHasEnded = true
        engine.reloadFails = true
        do {
            try await HybridSeekTransport.perform(
                engine: engine, target: 0, intent: .position,
                isCurrent: { true }, acceptLanding: { _ in .restoreRate(1) }
            )
            XCTFail("Expected the explicit replay reload to fail")
        } catch {
            XCTAssertEqual(error as? RecordingSeekEngine.Failure, .reload)
        }
        XCTAssertEqual(engine.commands, [.reload])
    }

    func testPinnedAetherTailSeekDoesNotTakeItsImplicitReplayPath() async throws {
        let engine = try AetherEngine()
        engine.duration = 1_343.44
        engine.state = .playing
        let result = try await HybridSeekTransport.perform(
            engine: engine, target: 1_343.34, intent: .position,
            isCurrent: { true }, acceptLanding: { _ in .restoreRate(1) }
        )
        await Task.yield()

        XCTAssertEqual(result, .parked)
        XCTAssertEqual(engine.currentTime, 1_343.34, accuracy: 0.000_001)
        XCTAssertEqual(engine.state, .paused)
    }
}

@MainActor
private final class SeekTimeline {
    var authority = HybridHLSTimelineAuthority(
        duration: 1_343.44, initialPosition: 1_314, uptime: 0
    )

    init(rate: Float = 1) {
        authority.markReady(uptime: 0)
        authority.setRate(rate, uptime: 0)
    }

    var state: HybridHLSTimelineState { authority.snapshot(uptime: 0) }

    func begin(to target: Double) -> UInt64 {
        authority.seek(to: target, uptime: 0)
    }

    func setRate(_ rate: Float) { authority.setRate(rate, uptime: 0) }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.seekGeneration == generation
    }

    func accept(
        _ disposition: HybridSeekEndDisposition,
        generation: UInt64
    ) -> HybridSeekTransport.Completion {
        guard isCurrent(generation) else { return .superseded }
        switch disposition {
        case .completed:
            _ = authority.completeSeek(generation: generation, uptime: 0)
        case .none, .parked:
            if disposition == .parked { setRate(0) }
            _ = authority.recordResolvedSegment(
                Int(state.currentTime), requestGeneration: generation, uptime: 0
            )
        }
        return .restoreRate(state.rate)
    }
}

@MainActor
private final class RecordingSeekEngine: HybridSeekEngine {
    enum Command: Equatable {
        case reload, seek(Double), pause, rate(Float), play
    }
    enum Failure: Error { case reload }

    let duration = 1_343.44
    let isLive = false
    var hybridHasEnded = false
    var currentTime = 1_314.0
    var isPlaying = true
    var commands: [Command] = []
    var playCount = 0
    var reloadFails = false
    var suspendSeeks = false
    var landingOffset = 0.0
    let seekStarts: AsyncStream<Double>
    private let starts: AsyncStream<Double>.Continuation
    private var seeks: [Double: CheckedContinuation<Void, Never>] = [:]
    private var generation = 0

    init() {
        (seekStarts, starts) = AsyncStream<Double>.makeStream()
    }

    func seek(to seconds: Double) async {
        commands.append(.seek(seconds))
        generation += 1
        let operation = generation
        if suspendSeeks {
            await withCheckedContinuation { continuation in
                seeks[seconds] = continuation
                starts.yield(seconds)
            }
        }
        guard operation == generation else { return }
        currentTime = seconds + landingOffset
        if HybridSeekEndPolicy.isAtEnd(time: currentTime, duration: duration, isLive: false) {
            isPlaying = false
        }
    }

    func finishSeek(to target: Double) {
        seeks.removeValue(forKey: target)?.resume()
    }

    func reloadAtCurrentPosition() async throws {
        commands.append(.reload)
        if reloadFails { throw Failure.reload }
        hybridHasEnded = false
    }

    func pause() { commands.append(.pause); isPlaying = false }
    func setRate(_ rate: Float) { commands.append(.rate(rate)) }

    func play() {
        commands.append(.play)
        playCount += 1
        if HybridSeekEndPolicy.isAtEnd(time: currentTime, duration: duration, isLive: false) {
            currentTime = 0
        }
        isPlaying = true
    }
}
