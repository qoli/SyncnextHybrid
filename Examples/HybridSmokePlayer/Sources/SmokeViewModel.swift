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

    @Published private(set) var runState: RunState = .setup
    @Published private(set) var statusMessage =
        "Enter one explicit seekable VOD source"
    @Published private(set) var sourceDisplay = ""
    @Published private(set) var routeName = "unbound"
    @Published private(set) var phaseName = "idle"
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var hasAttachedSession = false

    let playerViewController: AVPlayerViewController

    private var session: HybridPlaybackSession?
    private var runTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var emitter: SmokeEventEmitter?
    private var didInspectEnvironment = false

    init() {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        playerViewController = controller
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
        eventTask?.cancel()
        runTask = nil
        eventTask = nil
        session?.stop()
        session = nil
        emitter = nil
        playerViewController.player = nil
        hasAttachedSession = false
        routeName = "unbound"
        phaseName = "idle"
        currentTime = 0
        duration = 0
        runState = .setup
        statusMessage = "Enter one explicit seekable VOD source"
    }

    private func start(_ configuration: SmokeConfiguration) {
        guard runTask == nil else {
            return
        }
        let eventEmitter = SmokeEventEmitter(
            configuration: configuration
        )
        emitter = eventEmitter
        sourceDisplay = configuration.displaySource
        runState = .loading
        statusMessage = "Creating Hybrid playback session"
        eventEmitter.emit(
            "run_started",
            metrics: [
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
                try await self.run(
                    configuration,
                    emitter: eventEmitter
                )
            } catch is CancellationError {
                eventEmitter.emit("run_cancelled")
            } catch {
                self.fail(error, emitter: eventEmitter)
            }
            self.runTask = nil
        }
    }

    private func run(
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
        hasAttachedSession = true
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
                "message": error.localizedDescription,
            ]
        )
    }

    private func fail(
        _ error: Error,
        emitter: SmokeEventEmitter
    ) {
        session?.pause()
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
        }
        emitter.emit("run_failed", metrics: metrics)
    }
}
