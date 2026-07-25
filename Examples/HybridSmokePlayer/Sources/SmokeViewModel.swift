import AetherEngine
import AVKit
import Combine
import Foundation
import SyncnextHybrid

@MainActor
final class SmokeViewModel: ObservableObject {
    enum RunState: Equatable {
        case setup
        case loading
        case checkingStartup
        case seeking
        case checkingPostSeek
        case manualControl
        case passed
        case failed

        var title: String {
            switch self {
            case .setup:
                "Ready"
            case .loading:
                "Loading"
            case .checkingStartup:
                "Checking startup progress"
            case .seeking:
                "Checking seek"
            case .checkingPostSeek:
                "Checking post-seek progress"
            case .manualControl:
                "Manual Aether seek"
            case .passed:
                "PASS"
            case .failed:
                "FAIL"
            }
        }
    }

    @Published var sourceURLText = "http://192.168.6.119:8765/progressive-hybrid-mpeg2-interlaced-ac3-5min.mkv"
    @Published var headersJSONText = ""
    @Published var seekSecondsText =
        String(SmokeConfiguration.defaultSeekSeconds)
    @Published var selectedMode: SmokePlaybackMode = .aetherEngine

    @Published private(set) var runState: RunState = .setup
    @Published private(set) var statusMessage =
        "Enter one explicit seekable VOD source"
    @Published private(set) var sourceDisplay = ""
    @Published private(set) var routeName = "unbound"
    @Published private(set) var phaseName = "idle"
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var hasActivePresentation = false
    @Published private(set) var activeMode: SmokePlaybackMode?
    @Published private(set) var aetherEngine: AetherEngine?
    @Published private(set) var activeSeekTarget: Double?

    let playerViewController: AVPlayerViewController

    private var session: HybridPlaybackSession?
    private var runTask: Task<Void, Never>?
    private var manualSeekTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var emitter: SmokeEventEmitter?
    private var didInspectEnvironment = false
    private var aetherRequestedRate: Float = 0
    private var aetherObservations = Set<AnyCancellable>()

    init() {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        playerViewController = controller
    }

    var canManuallySeekAether: Bool {
        guard activeMode == .aetherEngine,
              aetherEngine != nil,
              manualSeekTask == nil,
              let activeSeekTarget,
              activeSeekTarget.isFinite,
              activeSeekTarget > 0,
              duration.isFinite,
              duration > activeSeekTarget else {
            return false
        }
        return true
    }

    func startFromEnvironmentIfPresent(
        _ environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) {
        guard !didInspectEnvironment else {
            return
        }
        didInspectEnvironment = true

        do {
            guard let configuration =
                try SmokeConfiguration.fromEnvironment(environment) else {
                return
            }
            start(configuration)
        } catch {
            failConfiguration(error)
        }
    }

    func runInteractive() {
        do {
            let configuration = try SmokeConfiguration.interactive(
                mode: selectedMode,
                rawURL: sourceURLText,
                rawHeaders: headersJSONText,
                rawSeekSeconds: seekSecondsText
            )
            start(configuration)
        } catch {
            failConfiguration(error)
        }
    }

    func reset() {
        runTask?.cancel()
        manualSeekTask?.cancel()
        eventTask?.cancel()
        runTask = nil
        manualSeekTask = nil
        eventTask = nil
        session?.stop()
        session = nil
        aetherEngine?.stop()
        aetherEngine = nil
        aetherObservations.removeAll()
        aetherRequestedRate = 0
        emitter = nil
        playerViewController.player = nil
        hasActivePresentation = false
        activeMode = nil
        activeSeekTarget = nil
        routeName = "unbound"
        phaseName = "idle"
        currentTime = 0
        duration = 0
        runState = .setup
        statusMessage = "Enter one explicit seekable VOD source"
    }

    func seekAetherToConfiguredTarget() {
        guard canManuallySeekAether,
              let engine = aetherEngine,
              let target = activeSeekTarget,
              let eventEmitter = emitter else {
            return
        }

        let automationTask = runTask
        let shouldResume = aetherRequestedRate > 0
        automationTask?.cancel()

        manualSeekTask = Task { [weak self, weak engine] in
            if let automationTask {
                await automationTask.value
            }
            guard let self, let engine else {
                return
            }
            defer {
                self.manualSeekTask = nil
            }

            do {
                try Task.checkCancellation()
                try self.requireAetherPresentation(engine)

                self.runState = .manualControl
                self.statusMessage =
                    "Manually seeking AetherEngine to "
                    + "\(SmokeEventEmitter.number(target))s"
                self.aetherRequestedRate = 0
                engine.pause()

                let requestedSnapshot =
                    try self.validatedAetherSnapshot(for: engine)
                try SmokePolicy.validateDuration(
                    requestedSnapshot.duration,
                    seekSeconds: target
                )
                eventEmitter.emit(
                    "manual_seek_requested",
                    metrics: eventEmitter.metrics(
                        for: requestedSnapshot,
                        extra: [
                            "target_seconds":
                                SmokeEventEmitter.number(target),
                            "resume_after_seek":
                                shouldResume ? "true" : "false",
                        ]
                    )
                )

                await engine.seek(to: target)
                try Task.checkCancellation()
                let landedSnapshot =
                    try self.validatedAetherSnapshot(for: engine)
                try SmokePolicy.validateSeekLanding(
                    target: target,
                    actual: landedSnapshot.currentTime
                )
                self.updateSnapshot(landedSnapshot)

                if shouldResume {
                    self.aetherRequestedRate = 1
                    engine.play()
                }
                let finalSnapshot =
                    try self.validatedAetherSnapshot(for: engine)
                self.updateSnapshot(finalSnapshot)
                self.statusMessage = shouldResume
                    ? "Manual seek landed; playback resumed"
                    : "Manual seek landed; resume was not requested"
                eventEmitter.emit(
                    "manual_seek_landed",
                    metrics: eventEmitter.metrics(
                        for: finalSnapshot,
                        extra: [
                            "target_seconds":
                                SmokeEventEmitter.number(target),
                            "landing_error_seconds":
                                SmokeEventEmitter.number(
                                    abs(
                                        landedSnapshot.currentTime
                                        - target
                                    )
                                ),
                            "resumed":
                                shouldResume ? "true" : "false",
                        ]
                    )
                )
            } catch is CancellationError {
                eventEmitter.emit("manual_seek_cancelled")
            } catch {
                self.failManualAetherSeek(
                    error,
                    target: target,
                    emitter: eventEmitter
                )
            }
        }
    }

    private func start(_ configuration: SmokeConfiguration) {
        guard runTask == nil, manualSeekTask == nil else {
            return
        }
        let eventEmitter = SmokeEventEmitter(
            configuration: configuration
        )
        emitter = eventEmitter
        sourceDisplay = configuration.displaySource
        activeMode = configuration.mode
        activeSeekTarget = configuration.seekSeconds
        runState = .loading
        statusMessage = configuration.mode == .aetherEngine
            ? "Creating direct AetherEngine baseline"
            : "Creating Hybrid playback session"
        eventEmitter.emit(
            "run_started",
            metrics: [
                "mode": configuration.mode.rawValue,
                "header_names":
                    configuration.httpHeaders.keys.sorted()
                    .joined(separator: ","),
                "seek_target_seconds":
                    SmokeEventEmitter.number(
                        configuration.seekSeconds
                    ),
                "expected_route":
                    configuration.expectedRoute?.rawValue
                    ?? "observe",
            ]
        )

        runTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                switch configuration.mode {
                case .aetherEngine:
                    try await self.runAether(
                        configuration,
                        emitter: eventEmitter
                    )
                case .hybridAVKit:
                    try await self.runHybrid(
                        configuration,
                        emitter: eventEmitter
                    )
                }
            } catch is CancellationError {
                eventEmitter.emit("run_cancelled")
            } catch {
                self.fail(error, emitter: eventEmitter)
            }
            self.runTask = nil
        }
    }

    private func runAether(
        _ configuration: SmokeConfiguration,
        emitter: SmokeEventEmitter
    ) async throws {
        let engine: AetherEngine
        do {
            engine = try AetherEngine()
        } catch {
            throw SmokeFailure.aetherInitializationFailed(
                String(describing: error)
            )
        }

        aetherEngine = engine
        observeAether(engine)
        hasActivePresentation = true
        updateSnapshot(aetherSnapshot(for: engine))

        // Let SwiftUI install AetherPlayerSurface before load creates the
        // active rendering layer. bind(view:) is idempotent and remains the
        // only presentation path for this mode.
        await Task.yield()
        try Task.checkCancellation()
        try requireAetherPresentation(engine)

        let options = LoadOptions(
            httpHeaders: configuration.httpHeaders,
            autoplay: false
        )
        do {
            try await engine.load(
                url: configuration.sourceURL,
                options: options
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SmokeFailure.aetherSourceLoadFailed(
                String(describing: error)
            )
        }
        try Task.checkCancellation()

        var snapshot = try presentedAetherSnapshot(for: engine)
        updateSnapshot(snapshot)
        emitter.emit(
            "aether_surface_installed",
            metrics: emitter.metrics(
                for: snapshot,
                extra: [
                    "controller_binding": "not_applicable",
                ]
            )
        )

        statusMessage =
            "Waiting for a paused finite AetherEngine VOD snapshot"
        snapshot = try await requireAetherReadySnapshot(
            engine,
            emitter: emitter
        )
        try SmokePolicy.validateDuration(
            snapshot.duration,
            seekSeconds: configuration.seekSeconds
        )
        try SmokePolicy.validateInitialTime(snapshot.currentTime)

        runState = .checkingStartup
        statusMessage =
            "Requiring 2 seconds of direct AetherEngine media progress"
        aetherRequestedRate = 1
        engine.play()
        emitter.emit(
            "play_requested",
            metrics: emitter.metrics(
                for: try validatedAetherSnapshot(for: engine)
            )
        )
        let startupAdvance = try await requireAetherProgress(
            engine,
            minimumAdvance:
                SmokePolicy.minimumStartupProgressSeconds,
            stage: "startup",
            emitter: emitter
        )
        emitter.emit(
            "startup_progress_passed",
            metrics: emitter.metrics(
                for: try validatedAetherSnapshot(for: engine),
                extra: [
                    "progress_seconds":
                        SmokeEventEmitter.number(startupAdvance),
                ]
            )
        )

        runState = .seeking
        statusMessage =
            "Seeking AetherEngine to \(SmokeEventEmitter.number(configuration.seekSeconds))s"
        aetherRequestedRate = 0
        engine.pause()
        emitter.emit(
            "seek_requested",
            metrics: emitter.metrics(
                for: try validatedAetherSnapshot(for: engine),
                extra: [
                    "target_seconds":
                        SmokeEventEmitter.number(
                            configuration.seekSeconds
                        ),
                ]
            )
        )
        await engine.seek(to: configuration.seekSeconds)
        try Task.checkCancellation()
        snapshot = try validatedAetherSnapshot(for: engine)
        updateSnapshot(snapshot)
        try SmokePolicy.validateSeekLanding(
            target: configuration.seekSeconds,
            actual: snapshot.currentTime
        )
        emitter.emit(
            "seek_landed",
            metrics: emitter.metrics(
                for: snapshot,
                extra: [
                    "target_seconds":
                        SmokeEventEmitter.number(
                            configuration.seekSeconds
                        ),
                    "landing_error_seconds":
                        SmokeEventEmitter.number(
                            abs(
                                snapshot.currentTime
                                - configuration.seekSeconds
                            )
                        ),
                ]
            )
        )

        runState = .checkingPostSeek
        statusMessage =
            "Requiring 2 seconds of post-seek AetherEngine progress"
        aetherRequestedRate = 1
        engine.play()
        let postSeekAdvance = try await requireAetherProgress(
            engine,
            minimumAdvance:
                SmokePolicy.minimumPostSeekProgressSeconds,
            stage: "post_seek",
            emitter: emitter
        )

        snapshot = try validatedAetherSnapshot(for: engine)
        runState = .passed
        statusMessage =
            "Direct AetherEngine playback and seek passed; playback remains active"
        emitter.emit(
            "run_passed",
            metrics: emitter.metrics(
                for: snapshot,
                extra: [
                    "startup_progress_seconds":
                        SmokeEventEmitter.number(startupAdvance),
                    "post_seek_progress_seconds":
                        SmokeEventEmitter.number(postSeekAdvance),
                    "controller_binding": "not_applicable",
                ]
            )
        )
    }

    private func runHybrid(
        _ configuration: SmokeConfiguration,
        emitter: SmokeEventEmitter
    ) async throws {
        let request = try HybridPlaybackRequest(
            url: configuration.sourceURL,
            httpHeaders: configuration.httpHeaders
        )
        let playbackSession = try await HybridPlaybackSession(
            request: request
        )
        try Task.checkCancellation()

        session = playbackSession
        playerViewController.loadViewIfNeeded()
        try playbackSession.attach(to: playerViewController)
        hasActivePresentation = true
        observeEvents(from: playbackSession, emitter: emitter)

        statusMessage =
            "Waiting for a paused finite Hybrid VOD snapshot"
        let initial = try await requireReadySnapshot(
            playbackSession,
            emitter: emitter
        )
        updateSnapshot(initial)
        try SmokePolicy.validateDuration(
            initial.duration,
            seekSeconds: configuration.seekSeconds
        )
        try SmokePolicy.validateInitialTime(initial.currentTime)
        try requireBinding(playbackSession)

        if let expectedRoute = configuration.expectedRoute,
           expectedRoute.rawValue != initial.route.smokeName {
            throw SmokeFailure.unexpectedRoute(
                expected: expectedRoute.rawValue,
                actual: initial.route.smokeName
            )
        }

        let fixedRoute = initial.route
        emitter.emit(
            "session_attached",
            metrics: emitter.metrics(
                for: initial,
                extra: [
                    "controller_binding": "matched",
                    "audio_track_count":
                        String(initial.audioTracks.count),
                    "subtitle_track_count":
                        String(initial.subtitleTracks.count),
                ]
            )
        )

        runState = .checkingStartup
        statusMessage = "Requiring 2 seconds of authoritative media progress"
        playbackSession.play()
        emitter.emit(
            "play_requested",
            metrics: emitter.metrics(for: playbackSession.snapshot)
        )
        let startupAdvance = try await requireProgress(
            playbackSession,
            expectedRoute: fixedRoute,
            minimumAdvance:
                SmokePolicy.minimumStartupProgressSeconds,
            stage: "startup",
            emitter: emitter
        )
        emitter.emit(
            "startup_progress_passed",
            metrics: emitter.metrics(
                for: playbackSession.snapshot,
                extra: [
                    "progress_seconds":
                        SmokeEventEmitter.number(startupAdvance),
                ]
            )
        )

        runState = .seeking
        statusMessage =
            "Seeking to \(SmokeEventEmitter.number(configuration.seekSeconds))s"
        playbackSession.pause()
        emitter.emit(
            "seek_requested",
            metrics: emitter.metrics(
                for: playbackSession.snapshot,
                extra: [
                    "target_seconds":
                        SmokeEventEmitter.number(
                            configuration.seekSeconds
                        ),
                ]
            )
        )
        try await playbackSession.seek(to: configuration.seekSeconds)
        try requireBinding(playbackSession)
        try requireRoute(
            playbackSession.snapshot.route,
            expected: fixedRoute
        )
        try SmokePolicy.validateSeekLanding(
            target: configuration.seekSeconds,
            actual: playbackSession.snapshot.currentTime
        )
        emitter.emit(
            "seek_landed",
            metrics: emitter.metrics(
                for: playbackSession.snapshot,
                extra: [
                    "target_seconds":
                        SmokeEventEmitter.number(
                            configuration.seekSeconds
                        ),
                    "landing_error_seconds":
                        SmokeEventEmitter.number(
                            abs(
                                playbackSession.snapshot.currentTime
                                - configuration.seekSeconds
                            )
                        ),
                ]
            )
        )

        runState = .checkingPostSeek
        statusMessage =
            "Requiring 2 seconds of post-seek media progress"
        playbackSession.play()
        let postSeekAdvance = try await requireProgress(
            playbackSession,
            expectedRoute: fixedRoute,
            minimumAdvance:
                SmokePolicy.minimumPostSeekProgressSeconds,
            stage: "post_seek",
            emitter: emitter
        )

        runState = .passed
        statusMessage =
            "Playback and seek smoke passed; playback remains active"
        emitter.emit(
            "run_passed",
            metrics: emitter.metrics(
                for: playbackSession.snapshot,
                extra: [
                    "startup_progress_seconds":
                        SmokeEventEmitter.number(startupAdvance),
                    "post_seek_progress_seconds":
                        SmokeEventEmitter.number(postSeekAdvance),
                    "controller_binding": "matched",
                ]
            )
        )
    }

    private func aetherSnapshot(
        for engine: AetherEngine
    ) -> AetherSmokeSnapshot {
        AetherSmokeSnapshot(
            engine: engine,
            requestedRate: aetherRequestedRate
        )
    }

    private func validatedAetherSnapshot(
        for engine: AetherEngine
    ) throws -> AetherSmokeSnapshot {
        let snapshot = try presentedAetherSnapshot(for: engine)
        try AetherSmokeState.validateVideo(
            width: snapshot.videoWidth,
            height: snapshot.videoHeight,
            backend: snapshot.backend
        )
        return snapshot
    }

    private func presentedAetherSnapshot(
        for engine: AetherEngine
    ) throws -> AetherSmokeSnapshot {
        try requireAetherPresentation(engine)
        return aetherSnapshot(for: engine)
    }

    private func requireAetherPresentation(
        _ engine: AetherEngine
    ) throws {
        guard activeMode == .aetherEngine,
              aetherEngine === engine,
              hasActivePresentation else {
            throw SmokeFailure.aetherPresentationChanged
        }
    }

    private func requireAetherReadySnapshot(
        _ engine: AetherEngine,
        emitter: SmokeEventEmitter
    ) async throws -> AetherSmokeSnapshot {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var checkpointIndex = 0

        while true {
            try Task.checkCancellation()
            let snapshot = try presentedAetherSnapshot(for: engine)
            updateSnapshot(snapshot)

            if case .error(let message) = snapshot.phase {
                throw SmokeFailure.playerFailed(message)
            }
            if snapshot.phase == .ended {
                throw SmokeFailure.endedBeforeProgress(
                    stage: "session_readiness"
                )
            }

            if snapshot.duration.isFinite,
               snapshot.duration > 0,
               snapshot.currentTime.isFinite,
               snapshot.currentTime
                >= SmokePolicy.minimumInitialTimeSeconds,
               snapshot.phase == .paused {
                try AetherSmokeState.validateVideo(
                    width: snapshot.videoWidth,
                    height: snapshot.videoHeight,
                    backend: snapshot.backend
                )
                return snapshot
            }

            let elapsed =
                ProcessInfo.processInfo.systemUptime - startedAt
            while checkpointIndex
                    < SmokePolicy
                        .readinessDiagnosticCheckpointsSeconds.count,
                  elapsed
                    >= SmokePolicy
                        .readinessDiagnosticCheckpointsSeconds[
                            checkpointIndex
                        ] {
                let checkpoint =
                    SmokePolicy
                        .readinessDiagnosticCheckpointsSeconds[
                            checkpointIndex
                        ]
                emitter.emit(
                    "awaiting_session_readiness",
                    metrics: emitter.metrics(
                        for: snapshot,
                        extra: [
                            "elapsed_seconds":
                                SmokeEventEmitter.number(checkpoint),
                            "required_state":
                                "paused_finite_seekable_vod",
                        ]
                    )
                )
                checkpointIndex += 1
            }
            if elapsed
                >= SmokePolicy.maximumSessionReadinessSeconds {
                throw SmokeFailure.sessionReadinessTimeout(
                    phase: snapshot.phase.smokeName,
                    duration: snapshot.duration,
                    timeout:
                        SmokePolicy.maximumSessionReadinessSeconds
                )
            }

            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func requireAetherProgress(
        _ engine: AetherEngine,
        minimumAdvance: Double,
        stage: String,
        emitter: SmokeEventEmitter
    ) async throws -> Double {
        let initial = try validatedAetherSnapshot(for: engine)
        let baseline = initial.currentTime
        try SmokePolicy.validateInitialTime(baseline)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var checkpointIndex = 0

        while true {
            try Task.checkCancellation()
            let snapshot = try validatedAetherSnapshot(for: engine)
            updateSnapshot(snapshot)

            if case .error(let message) = snapshot.phase {
                throw SmokeFailure.playerFailed(message)
            }
            if snapshot.phase == .ended {
                throw SmokeFailure.endedBeforeProgress(stage: stage)
            }

            let advance = try SmokePolicy.progress(
                from: baseline,
                to: snapshot.currentTime
            )
            if advance >= minimumAdvance {
                return advance
            }

            let elapsed =
                ProcessInfo.processInfo.systemUptime - startedAt
            while checkpointIndex
                    < SmokePolicy
                        .diagnosticCheckpointsSeconds.count,
                  elapsed
                    >= SmokePolicy
                        .diagnosticCheckpointsSeconds[checkpointIndex] {
                let checkpoint =
                    SmokePolicy
                        .diagnosticCheckpointsSeconds[checkpointIndex]
                emitter.emit(
                    "awaiting_media_progress",
                    metrics: emitter.metrics(
                        for: snapshot,
                        extra: [
                            "stage": stage,
                            "elapsed_seconds":
                                SmokeEventEmitter.number(checkpoint),
                            "minimum_required_seconds":
                                SmokeEventEmitter.number(
                                    minimumAdvance
                                ),
                            "observed_progress_seconds":
                                SmokeEventEmitter.number(advance),
                        ]
                    )
                )
                checkpointIndex += 1
            }
            if elapsed >= SmokePolicy.maximumZeroProgressSeconds {
                throw SmokeFailure.noMediaProgress(
                    stage: stage,
                    baseline: baseline,
                    currentTime: snapshot.currentTime,
                    timeout:
                        SmokePolicy.maximumZeroProgressSeconds
                )
            }

            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func observeAether(_ engine: AetherEngine) {
        aetherObservations.removeAll()

        engine.objectWillChange
            .sink { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self,
                          let engine,
                          self.aetherEngine === engine else {
                        return
                    }
                    self.updateSnapshot(
                        self.aetherSnapshot(for: engine)
                    )
                }
            }
            .store(in: &aetherObservations)

        engine.clock.$currentTime
            .sink { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self,
                          let engine,
                          self.aetherEngine === engine else {
                        return
                    }
                    self.updateSnapshot(
                        self.aetherSnapshot(for: engine)
                    )
                }
            }
            .store(in: &aetherObservations)
    }

    private func requireReadySnapshot(
        _ playbackSession: HybridPlaybackSession,
        emitter: SmokeEventEmitter
    ) async throws -> HybridPlaybackSnapshot {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var checkpointIndex = 0

        while true {
            try Task.checkCancellation()
            try requireBinding(playbackSession)
            let snapshot = playbackSession.snapshot
            updateSnapshot(snapshot)

            if case .failed(let message) = snapshot.phase {
                throw SmokeFailure.playerFailed(message)
            }
            if snapshot.phase == .ended {
                throw SmokeFailure.endedBeforeProgress(
                    stage: "session_readiness"
                )
            }

            if snapshot.duration.isFinite,
               snapshot.duration > 0,
               snapshot.currentTime.isFinite,
               snapshot.currentTime
                >= SmokePolicy.minimumInitialTimeSeconds,
               snapshot.phase == .paused {
                return snapshot
            }

            let elapsed =
                ProcessInfo.processInfo.systemUptime - startedAt
            while checkpointIndex
                    < SmokePolicy
                        .readinessDiagnosticCheckpointsSeconds.count,
                  elapsed
                    >= SmokePolicy
                        .readinessDiagnosticCheckpointsSeconds[
                            checkpointIndex
                        ] {
                let checkpoint =
                    SmokePolicy
                        .readinessDiagnosticCheckpointsSeconds[
                            checkpointIndex
                        ]
                emitter.emit(
                    "awaiting_session_readiness",
                    metrics: emitter.metrics(
                        for: snapshot,
                        extra: [
                            "elapsed_seconds":
                                SmokeEventEmitter.number(checkpoint),
                            "required_state":
                                "paused_finite_seekable_vod",
                        ]
                    )
                )
                checkpointIndex += 1
            }
            if elapsed
                >= SmokePolicy.maximumSessionReadinessSeconds {
                throw SmokeFailure.sessionReadinessTimeout(
                    phase: snapshot.phase.smokeName,
                    duration: snapshot.duration,
                    timeout:
                        SmokePolicy.maximumSessionReadinessSeconds
                )
            }

            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func requireProgress(
        _ playbackSession: HybridPlaybackSession,
        expectedRoute: HybridPlaybackRoute,
        minimumAdvance: Double,
        stage: String,
        emitter: SmokeEventEmitter
    ) async throws -> Double {
        let baseline = playbackSession.snapshot.currentTime
        try SmokePolicy.validateInitialTime(baseline)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var checkpointIndex = 0

        while true {
            try Task.checkCancellation()
            try requireBinding(playbackSession)

            let snapshot = playbackSession.snapshot
            updateSnapshot(snapshot)
            try requireRoute(snapshot.route, expected: expectedRoute)
            let advance = try SmokePolicy.progress(
                from: baseline,
                to: snapshot.currentTime
            )
            if advance >= minimumAdvance {
                return advance
            }

            if case .failed(let message) = snapshot.phase {
                throw SmokeFailure.playerFailed(message)
            }
            if snapshot.phase == .ended {
                throw SmokeFailure.endedBeforeProgress(stage: stage)
            }

            let elapsed =
                ProcessInfo.processInfo.systemUptime - startedAt
            while checkpointIndex
                    < SmokePolicy
                        .diagnosticCheckpointsSeconds.count,
                  elapsed
                    >= SmokePolicy
                        .diagnosticCheckpointsSeconds[checkpointIndex] {
                let checkpoint =
                    SmokePolicy
                        .diagnosticCheckpointsSeconds[checkpointIndex]
                emitter.emit(
                    "awaiting_media_progress",
                    metrics: emitter.metrics(
                        for: snapshot,
                        extra: [
                            "stage": stage,
                            "elapsed_seconds":
                                SmokeEventEmitter.number(checkpoint),
                            "minimum_required_seconds":
                                SmokeEventEmitter.number(
                                    minimumAdvance
                                ),
                            "observed_progress_seconds":
                                SmokeEventEmitter.number(advance),
                        ]
                    )
                )
                checkpointIndex += 1
            }
            if elapsed >= SmokePolicy.maximumZeroProgressSeconds {
                throw SmokeFailure.noMediaProgress(
                    stage: stage,
                    baseline: baseline,
                    currentTime: snapshot.currentTime,
                    timeout:
                        SmokePolicy.maximumZeroProgressSeconds
                )
            }

            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func requireBinding(
        _ playbackSession: HybridPlaybackSession
    ) throws {
        guard session === playbackSession,
              playerViewController.player
                === playbackSession.avPlayer else {
            throw SmokeFailure.controllerBindingChanged
        }
    }

    private func requireRoute(
        _ route: HybridPlaybackRoute,
        expected: HybridPlaybackRoute
    ) throws {
        guard route == expected else {
            throw SmokeFailure.routeChanged(
                expected: expected.smokeName,
                actual: route.smokeName
            )
        }
    }

    private func observeEvents(
        from playbackSession: HybridPlaybackSession,
        emitter: SmokeEventEmitter
    ) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in playbackSession.events {
                guard let self, !Task.isCancelled else {
                    return
                }
                switch event {
                case .snapshot(let snapshot):
                    self.updateSnapshot(snapshot)
                case .playerBindingChanged(let route):
                    emitter.emit(
                        "player_binding_changed",
                        metrics: [
                            "route": route.smokeName,
                            "controller_binding":
                                self.playerViewController.player
                                    === playbackSession.avPlayer
                                ? "matched"
                                : "mismatched",
                        ]
                    )
                case .audioAnalysisUnavailable(let error):
                    emitter.emit(
                        "audio_analysis_unavailable",
                        metrics: [
                            "message":
                                error.localizedDescription,
                        ]
                    )
                }
            }
        }
    }

    private func updateSnapshot(
        _ snapshot: HybridPlaybackSnapshot
    ) {
        routeName = snapshot.route.smokeName
        phaseName = snapshot.phase.smokeName
        currentTime = snapshot.currentTime
        duration = snapshot.duration
    }

    private func updateSnapshot(
        _ snapshot: AetherSmokeSnapshot
    ) {
        routeName = "not_applicable"
        phaseName = snapshot.phase.smokeName
        currentTime = snapshot.currentTime
        duration = snapshot.duration
    }

    private func failConfiguration(_ error: Error) {
        let eventEmitter = SmokeEventEmitter(
            configurationFailure: ()
        )
        emitter = eventEmitter
        runState = .failed
        statusMessage = error.localizedDescription
        eventEmitter.emit(
            "run_failed",
            metrics: [
                "error_code": "invalid_configuration",
                "mode": "unavailable",
                "message": error.localizedDescription,
            ]
        )
    }

    private func failManualAetherSeek(
        _ error: Error,
        target: Double,
        emitter: SmokeEventEmitter
    ) {
        aetherRequestedRate = 0
        aetherEngine?.pause()
        runState = .failed
        statusMessage = emitter.redactor.sanitize(
            error.localizedDescription
        )
        let code =
            (error as? SmokeFailure)?.code
            ?? "manual_seek_error"
        var metrics = [
            "error_code": code,
            "message": error.localizedDescription,
            "target_seconds": SmokeEventEmitter.number(target),
        ]
        if let aetherEngine {
            metrics.merge(
                emitter.metrics(
                    for: aetherSnapshot(for: aetherEngine)
                ),
                uniquingKeysWith: { _, latest in latest }
            )
        }
        emitter.emit("manual_seek_failed", metrics: metrics)
    }

    private func fail(
        _ error: Error,
        emitter: SmokeEventEmitter
    ) {
        session?.pause()
        if let aetherEngine {
            aetherRequestedRate = 0
            aetherEngine.pause()
        }
        runState = .failed
        statusMessage = emitter.redactor.sanitize(
            error.localizedDescription
        )
        let code =
            (error as? SmokeFailure)?.code
            ?? (error is SmokeConfigurationError
                ? "invalid_configuration"
                : "session_error")
        var metrics = [
            "error_code": code,
            "message": error.localizedDescription,
        ]
        if let session {
            metrics.merge(
                emitter.metrics(for: session.snapshot),
                uniquingKeysWith: { _, latest in latest }
            )
        } else if let aetherEngine {
            metrics.merge(
                emitter.metrics(
                    for: aetherSnapshot(for: aetherEngine)
                ),
                uniquingKeysWith: { _, latest in latest }
            )
        }
        emitter.emit("run_failed", metrics: metrics)
    }
}
