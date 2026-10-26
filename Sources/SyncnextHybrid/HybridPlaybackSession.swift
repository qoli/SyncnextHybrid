#if os(tvOS)
import AetherEngine
import AVFoundation
import AVKit
import Combine
import CoreGraphics
import Foundation
import UIKit

@MainActor
public final class HybridPlaybackSession:
    NSObject,
    ObservableObject,
    @preconcurrency AVPlayerViewControllerDelegate
{
    public let request: HybridPlaybackRequest
    public let events: AsyncStream<HybridPlaybackEvent>

    private let userSubtitleSelectionSubject = PassthroughSubject<HybridMediaTrack?, Never>()

    /// Explicit UI actions only, including selecting Off when already off.
    public var userSubtitleSelections: AnyPublisher<HybridMediaTrack?, Never> {
        userSubtitleSelectionSubject.eraseToAnyPublisher()
    }

    @Published public private(set) var avPlayer: AVPlayer
    @Published public private(set) var snapshot: HybridPlaybackSnapshot

    /// Read-only renderer evidence for the standalone playback acceptance app.
    /// Proxy snapshots intentionally report the Server clock, so they cannot
    /// independently detect a renderer rewind behind an unchanged UI timeline.
    @_spi(SmokeTesting)
    public var rendererClockObservation: (
        currentTime: Double,
        sourceTime: Double,
        phase: HybridPlaybackPhase,
        isSeeking: Bool
    ) {
        (
            engine.currentTime,
            engine.sourceTime,
            Self.mapPhase(engine.playbackPhase),
            engine.isSeeking
        )
    }

    public var hlsProxyServerObservation:
        HybridHLSProxyServerObservation?
    {
        guard let proxyContext,
              avPlayer === proxyContext.player else {
            return nil
        }
        let state = proxyContext.timeline.state
        return HybridHLSProxyServerObservation(
            seekGeneration: state.seekGeneration,
            resolvedSegmentIndices: state.resolvedSegmentIndices
        )
    }

    private struct ProxyContext {
        let timeline: HybridHLSTimelineProxy
        let player: AVPlayer
        let duration: Double
    }

    private let engine: AetherEngine
    private let startupDiagnostics: HybridStartupDiagnostics
    private let surface: AetherPlayerView
    private let subtitleOverlay = HybridSubtitleOverlayView()
    private let proxyContext: ProxyContext?
    private let forceAVKitProxy: Bool
    private let sourceAdmission: HybridRemoteSourceAdmission
    private var manifestFallbackServer: HybridHLSManifestServer?
    private var proxyTimeline: HybridHLSTimelineProxy {
        guard let proxyContext else {
            preconditionFailure("Proxy timeline requested by native AVPlayer route")
        }
        return proxyContext.timeline
    }
    private var proxyPlayer: AVPlayer {
        guard let proxyContext else {
            preconditionFailure("Proxy player requested by native AVPlayer route")
        }
        return proxyContext.player
    }
    private var proxyDuration: Double {
        guard let proxyContext else {
            preconditionFailure("Proxy duration requested by native AVPlayer route")
        }
        return proxyContext.duration
    }
    private let diagnosticsID = String(
        UUID().uuidString.prefix(8)
    )
    private let eventContinuation: AsyncStream<HybridPlaybackEvent>.Continuation

    private weak var attachedController: AVPlayerViewController?
    private weak var previousControllerDelegate:
        (any AVPlayerViewControllerDelegate)?
    private var previousCustomMenuItems: [UIMenuElement] = []
    private var observations = Set<AnyCancellable>()
    private var proxyRateObservation: NSKeyValueObservation?
    private var proxyNavigationTasks:
        [UInt64: Task<Void, Error>] = [:]
    private var nativeSeekGeneration: UInt64 = 0
    private var nativeSeekInFlight = false
    private var nativePendingRate: Float?
    private var endDisposition: HybridSeekEndDisposition = .none
    private var replayTask: Task<Void, Never>?
    private var playbackFailure: HybridPlaybackError?
    private var hasPendingProxyNavigation: Bool {
        guard let proxyContext else { return false }
        return proxyNavigationTasks[proxyContext.timeline.state.seekGeneration] != nil
    }
    private var completedProxyClientSeekGenerations: Set<UInt64> = []
    private var pendingProxyClientSeekGeneration: UInt64?
    private struct PendingServerSeekContext {
        let oldTime: Double
        let origin: HybridProxyNavigation.Origin
        let intent: HybridPlaybackSeekIntent
    }
    private var pendingServerSeekContext: PendingServerSeekContext?
    private var requestedRate: Float = 1
    private var lastLoggedHLSMaterial: HybridHLSProxyMaterial?
    private var stopped = false
    private var foregroundRecovery =
        HybridForegroundRecoveryCoordinator()
    private var foregroundRecoveryTask: Task<Void, Never>?
    private var audioSelectionRevision: UInt64 = 0
    private var fingerprintCancellations: [UUID: @Sendable () -> Void] = [:]
    private var lastNativePlayerIdentity: ObjectIdentifier?

    private var vodBufferPolicy: HybridVODBufferPolicy?

    #if DEBUG
    public var vodNetworkTestObservation: (videoRoute: String, isLive: Bool, videoWidth: Int, videoHeight: Int) {
        (engine.videoRoute.rawValue, engine.isLive, Int(engine.sourceVideoWidth), Int(engine.sourceVideoHeight))
    }
    #endif

    private func configureVODBufferPolicy() {
        guard vodBufferPolicy?.player !== avPlayer else { return }
        let preference: TimeInterval
        #if DEBUG
        preference = request.vodNetworkTestVariant.map { $0.usesAdaptiveBuffer ? 0 : 12 }
            ?? request.preferredForwardBufferDuration
        #else
        preference = request.preferredForwardBufferDuration
        #endif
        vodBufferPolicy = HybridVODBufferPolicy(
            player: avPlayer,
            preferredForwardBufferDuration: preference,
            diagnosticSessionID: diagnosticsID,
            isEligible: { [weak self] player in
                guard let self else { return false }
                return !self.stopped && !self.engine.isLive
                    && self.engine.videoRoute == .loopback
                    && self.engine.currentAVPlayer === player
            }
        )
    }

    public init(request: HybridPlaybackRequest) async throws {
        HybridNetworkDiagnostics.installMediaRequestLogging()
        self.request = request
        startupDiagnostics = HybridStartupDiagnostics(sessionID: diagnosticsID)
        startupDiagnostics.mark("request")

        let eventPair = AsyncStream<HybridPlaybackEvent>.makeStream()
        events = eventPair.stream
        eventContinuation = eventPair.continuation

        do {
            engine = try AetherEngine()
        } catch {
            throw HybridPlaybackError.sourceLoadFailed(
                String(describing: error)
            )
        }
        surface = AetherPlayerView()
        engine.bind(view: surface)
        startupDiagnostics.observe(engine)

        let externalSubtitles = request.externalSubtitles.map {
            ExternalSubtitleTrack(
                url: $0.url,
                name: $0.name,
                language: $0.language,
                httpHeaders: $0.httpHeaders,
                formatHint: $0.formatHint
            )
        }
        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: request.url,
                httpHeaders: request.httpHeaders
            )
        sourceAdmission = admission
        startupDiagnostics.mark("admission-completed")
        forceAVKitProxy = admission.requiresAetherHLSVODRemux
        let originalPlan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: externalSubtitles,
            admission: admission
        )
        let prepared: (plan: HybridPlaybackPlan, server: HybridHLSManifestServer?)
        do {
            prepared = try await originalPlan.prepareManifestFallback()
        } catch is CancellationError {
            engine.unbind(view: surface)
            throw CancellationError()
        } catch {
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_MANIFEST_FALLBACK session=\(diagnosticsID) event=failed"
                    + " reason=preparation-failed"
            )
            engine.unbind(view: surface)
            throw HybridPlaybackError.sourceLoadFailed(String(describing: error))
        }
        let plan = prepared.plan
        manifestFallbackServer = prepared.server
        var initialized = false
        defer {
            if !initialized { prepared.server?.stop() }
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_ADMISSION "
                + "session=\(diagnosticsID) "
                + "\(admission.diagnosticFields) "
                + "originalSourceID="
                + HybridPlaybackPlan.sourceID(request.url) + " "
                + "\(plan.diagnosticFields) "
                + "nativeRemoteHLS=\(plan.options.nativeRemoteHLS) "
                + "heldSourceConnection=\(plan.options.heldSourceConnection) "
                + "progressiveSegmentDelivery=\(plan.options.progressiveSegmentDelivery) "
                + "isLive=\(plan.options.isLive) "
                + "forceAVKitProxy=\(forceAVKitProxy)"
                + " mediaRequestCoverage=engine-avio-and-hls-ingest"
        )
        do {
            startupDiagnostics.mark("renderer-load-begin", probeBytes: plan.options.probesize)
            try await engine.load(
                url: plan.url,
                startPosition: request.initialPosition,
                options: plan.options
            )
            startupDiagnostics.mark("renderer-load-completed")
        } catch {
            let nsError = error as NSError
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_LOAD "
                    + "session=\(diagnosticsID) event=failed "
                    + "errorType=\(String(describing: type(of: error))) "
                    + "domain=\(nsError.domain) code=\(nsError.code)"
            )
            engine.unbind(view: surface)
            throw HybridPlaybackError.sourceLoadFailed(
                String(describing: error)
            )
        }

        guard engine.currentAVPlayer != nil
                || engine.sourceVideoWidth > 0
                || engine.sourceVideoHeight > 0 else {
            engine.stop()
            engine.unbind(view: surface)
            throw HybridPlaybackError.pureAudioUnsupported
        }

        let initialRoute: HybridPlaybackRoute
        if let nativePlayer = engine.currentAVPlayer,
           !forceAVKitProxy {
            proxyContext = nil
            avPlayer = nativePlayer
            initialRoute = .nativeAVPlayer
            engine.unbind(view: surface)
            lastNativePlayerIdentity = ObjectIdentifier(nativePlayer)
        } else {
            let proxyDuration = try HybridProxyDurationPolicy.duration(
                admission: admission,
                engineDuration: engine.duration
            )
            let timeline = try await ProxyMediaFactory.makeTimeline(
                duration: proxyDuration,
                initialPosition: request.initialPosition ?? 0,
                initialBufferedThrough:
                    HybridHLSProxyMaterialPolicy.bufferedThrough(
                        bufferedPosition: engine.bufferedPosition,
                        renderedSourceTime: engine.sourceTime
                    )
            )
            let context = ProxyContext(
                timeline: timeline,
                player: timeline.player,
                duration: proxyDuration
            )
            proxyContext = context
            avPlayer = context.player
            initialRoute = .avKitProxy
            lastNativePlayerIdentity = nil
        }
        snapshot = Self.makeSnapshot(
            engine: engine,
            route: initialRoute,
            proxyState: proxyContext?.timeline.state,
            sourceAdmission: sourceAdmission,
            nativeRate: requestedRate,
            audioSelectionRevision: audioSelectionRevision
        )

        super.init()
        proxyContext?.timeline.setEventHandler { [weak self] event in
            self?.handleProxyServerEvent(event)
        }
        configureVODBufferPolicy()
        installObservers()
        applyAetherMaterial()
        if snapshot.route == .avKitProxy,
           let initialPosition = request.initialPosition,
           initialPosition > 0 {
            try await seek(to: initialPosition)
        }
        publishSnapshot()
        startupDiagnostics.mark("session-created")
        initialized = true
    }

    #if DEBUG
    /// Uses an already-prepared renderer and the real local HLS timeline for
    /// tvOS transport regression tests, without opening an external source.
    init(
        request: HybridPlaybackRequest,
        preparedEngine: AetherEngine,
        proxyTimeline: HybridHLSTimelineProxy
    ) {
        self.request = request
        engine = preparedEngine
        startupDiagnostics = HybridStartupDiagnostics(sessionID: diagnosticsID, recordsStartup: false)
        surface = AetherPlayerView()
        forceAVKitProxy = true
        sourceAdmission = .aetherDefault(.nonHTTPSource)
        let duration = proxyTimeline.state.duration
        proxyContext = ProxyContext(
            timeline: proxyTimeline,
            player: proxyTimeline.player,
            duration: duration
        )
        avPlayer = proxyTimeline.player
        let pair = AsyncStream<HybridPlaybackEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        snapshot = Self.makeSnapshot(
            engine: preparedEngine,
            route: .avKitProxy,
            proxyState: proxyTimeline.state,
            sourceAdmission: sourceAdmission,
            nativeRate: requestedRate,
            audioSelectionRevision: audioSelectionRevision
        )
        super.init()
        proxyTimeline.setEventHandler { [weak self] event in
            self?.handleProxyServerEvent(event)
        }
        // This initializer supplies a hostless renderer fixture. The real
        // Proxy observes its own AVPlayer transport; renderer material was
        // explicitly supplied by the timeline factory, not by a media host.
        installProxyRateObserver()
    }
    #endif

    public func attach(
        to controller: AVPlayerViewController
    ) throws {
        guard !stopped else {
            throw HybridPlaybackError.sessionStopped
        }
        if attachedController !== controller {
            detach()
        }
        attachedController = controller
        previousControllerDelegate = controller.delegate
        previousCustomMenuItems = controller.transportBarCustomMenuItems
        controller.delegate = self
        controller.player = avPlayer
        controller.transportBarCustomMenuItems =
            previousCustomMenuItems + makeTrackMenus()
        try updateSurfaceAttachment(for: snapshot.route)
    }

    public func detach() {
        guard let controller = attachedController else {
            return
        }
        surface.removeFromSuperview()
        subtitleOverlay.removeFromSuperview()
        engine.unbind(view: surface)
        controller.transportBarCustomMenuItems = previousCustomMenuItems
        controller.delegate = previousControllerDelegate
        controller.player = nil
        attachedController = nil
        previousControllerDelegate = nil
        previousCustomMenuItems = []
    }

    public func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        guard !stopped,
              attachedController === playerViewController,
              snapshot.route == .avKitProxy,
              let proxyContext else {
            return targetTime
        }
        proxyDiagnostics(
            "navigation-target-received",
            "old=\(oldTime.seconds)",
            "target=\(targetTime.seconds)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyContext.player.currentTime().seconds)",
            "duration=\(engine.duration)",
            "requestedRate=\(requestedRate)"
        )
        guard oldTime.seconds.isFinite,
              targetTime.seconds.isFinite,
              proxyContext.duration.isFinite,
              proxyContext.duration > 0 else {
            proxyDiagnostics(
                "navigation-target-rejected",
                "reason=invalid-time-or-duration"
            )
            return targetTime
        }

        let boundedOld = max(0, min(oldTime.seconds, proxyContext.duration))
        let boundedTarget = max(
            0,
            min(targetTime.seconds, proxyContext.duration)
        )
        endDisposition = .none
        // AVKit asks for its final user-selected time before it performs the
        // client seek. This is the deliberate fast path: establish the same
        // authoritative Server generation and waitingToPlay state, but send
        // Aether the operation directly from the AVKit UI callback instead of
        // reflecting it back through the Server's seekRequested event.
        let generation = proxyContext.timeline.prepareSeek(
            to: boundedTarget,
            emitsSeekRequest: false
        )
        pendingProxyClientSeekGeneration = generation
        proxyDiagnostics(
            "avkit-seek-projected",
            "generation=\(generation)",
            "target=\(boundedTarget)",
            "serverPhase=\(proxyContext.timeline.state.phase)"
        )
        forwardProxySeekToAether(
            HybridProxyNavigation(
                generation: generation,
                oldTime: boundedOld,
                targetTime: boundedTarget,
                origin: .avKit
            )
        )
        return CMTime(seconds: boundedTarget, preferredTimescale: 600)
    }

    public func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) {
        guard !stopped,
              attachedController === playerViewController,
              snapshot.route == .avKitProxy,
              let proxyContext else {
            return
        }
        // Completion observation only. The operation was already accepted in
        // timeToSeekAfterUserNavigatedFrom, before AVKit began its HLS seek.
        proxyDiagnostics(
            "navigation-will-resume",
            "old=\(oldTime.seconds)",
            "target=\(targetTime.seconds)",
            "serverGeneration=\(proxyContext.timeline.state.seekGeneration)",
            "serverPhase=\(proxyContext.timeline.state.phase)"
        )
        markAVKitProxyClientSeekCompleted(
            generation: proxyContext.timeline.state.seekGeneration
        )
    }

    public func play() {
        guard !stopped else {
            return
        }
        requestedRate = max(requestedRate, 1)
        if nativeSeekInFlight {
            nativePendingRate = requestedRate
            return
        }
        if snapshot.route == .avKitProxy, hasPendingProxyNavigation {
            commandProxyRate(requestedRate, reason: "play-during-navigation")
            publishSnapshot()
            return
        }
        if needsReplay {
            requestReplay()
            return
        }
        guard snapshot.route == .avKitProxy else {
            engine.play()
            engine.setRate(requestedRate)
            publishSnapshot()
            return
        }
        commandProxyRate(requestedRate, reason: "public-play")
        publishSnapshot()
    }

    public func pause() {
        guard !stopped else {
            return
        }
        replayTask?.cancel()
        guard snapshot.route == .avKitProxy else {
            if nativeSeekInFlight {
                nativePendingRate = 0
            }
            engine.pause()
            publishSnapshot()
            return
        }
        commandProxyRate(0, reason: "public-pause")
        publishSnapshot()
    }

    public func seek(
        to seconds: Double,
        intent: HybridPlaybackSeekIntent = .position
    ) async throws {
        try await navigate(to: seconds, intent: intent, replayRate: nil)
    }

    /// Replays through the same authoritative navigation as a normal seek.
    /// Aether never owns an independent rewind behind the AVKit timeline.
    public func replay() async throws {
        replayTask?.cancel()
        try await performReplay()
    }

    private func performReplay() async throws {
        try Task.checkCancellation()
        requestedRate = max(requestedRate, 1)
        try await navigate(
            to: 0,
            intent: .position,
            replayRate: requestedRate
        )
    }

    private func navigate(
        to seconds: Double,
        intent: HybridPlaybackSeekIntent,
        replayRate: Float?
    ) async throws {
        guard !stopped else {
            throw HybridPlaybackError.sessionStopped
        }
        try Task.checkCancellation()
        if replayRate == nil {
            replayTask?.cancel()
        }
        let target = try HybridSeekEndPolicy.target(
            requested: seconds,
            duration: engine.duration,
            isLive: engine.isLive,
            intent: intent
        )
        endDisposition = .none
        guard snapshot.route == .avKitProxy else {
            nativeSeekGeneration &+= 1
            let generation = nativeSeekGeneration
            nativeSeekInFlight = true
            nativePendingRate = replayRate
            defer {
                if generation == nativeSeekGeneration {
                    nativeSeekInFlight = false
                    nativePendingRate = nil
                }
            }
            try await HybridSeekTransport.perform(
                engine: engine,
                target: target,
                intent: intent,
                isCurrent: {
                    !self.stopped && generation == self.nativeSeekGeneration
                },
                acceptLanding: { disposition in
                    self.endDisposition = disposition
                    if let rate = self.nativePendingRate {
                        return .restoreRate(rate)
                    }
                    return .preserveTransport
                }
            )
            publishSnapshot()
            return
        }
        let oldTime = proxyTimeline.state.currentTime
        proxyDiagnostics(
            "public-seek-began",
            "target=\(target)",
            "intent=\(intent)",
            "requestedRate=\(requestedRate)",
            "enginePhase=\(engine.playbackPhase)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)"
        )
        pendingServerSeekContext = PendingServerSeekContext(
            oldTime: oldTime,
            origin: .programmatic,
            intent: intent
        )
        let generation = proxyTimeline.prepareSeek(to: target)
        if let replayRate {
            // The generation is already pending, so this rate cannot send
            // Play to a renderer that is still parked at the old endpoint.
            commandProxyRate(replayRate, reason: "public-replay")
        }
        requestProxyAuthoritySeek(
            to: target,
            reason: "public-seek-begin"
        )
        if let task = proxyNavigationTasks[generation] {
            try await task.value
        }
        publishSnapshot()
    }

    private var needsReplay: Bool {
        endDisposition != .none || engine.hybridHasEnded
            || HybridSeekEndPolicy.isAtEnd(
                time: engine.currentTime,
                duration: engine.duration,
                isLive: engine.isLive
            )
    }

    private func requestReplay() {
        guard replayTask == nil else { return }
        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.replayTask = nil }
            do {
                try await self.performReplay()
            } catch is CancellationError {
                return
            } catch {
                guard !self.stopped else { return }
                self.publishPlaybackFailure(
                    .sourceLoadFailed(String(describing: error))
                )
            }
        }
    }

    /// Client-side completion is diagnostic synchronization for App UI
    /// capture. It never replaces the HLS Proxy Server's seek authority.
    public func hasAVKitProxyClientCompletedSeek(
        generation: UInt64
    ) -> Bool {
        completedProxyClientSeekGenerations.contains(generation)
    }

    public func setRate(_ rate: Float) {
        guard !stopped else {
            return
        }
        let bounded = max(0, min(rate, engine.maxSupportedRate))
        requestedRate = bounded
        if nativeSeekInFlight {
            if bounded == 0 || (nativePendingRate ?? 0) > 0 {
                nativePendingRate = bounded
            }
            engine.setRate(bounded)
            return
        }
        if snapshot.route == .avKitProxy, hasPendingProxyNavigation {
            commandProxyRate(bounded, reason: "rate-during-navigation")
            return
        }
        if bounded > 0, needsReplay {
            // A speed selection at the end is not a replay request.
            engine.setRate(bounded)
            publishSnapshot()
            return
        }
        guard snapshot.route == .avKitProxy else {
            if bounded == 0 {
                engine.pause()
            } else {
                engine.setRate(bounded)
            }
            publishSnapshot()
            return
        }
        commandProxyRate(bounded, reason: "public-set-rate")
        publishSnapshot()
    }

    /// Accepts mounted-player lifecycle edges. The presentation layer only
    /// reports UIKit state; this session owns recovery, route rebinding, and
    /// transport restoration.
    public func handleLifecycle(
        _ event: HybridPlaybackLifecycleEvent
    ) {
        guard !stopped else {
            lifecycleDiagnostics(
                "event-ignored",
                "reason=session-stopped",
                "eventName=\(event)"
            )
            return
        }
        switch event {
        case .enteredBackground:
            foregroundRecoveryTask?.cancel()
            foregroundRecoveryTask = nil
            let resumeRate = foregroundResumeRate()
            guard let recovery = foregroundRecovery.enterBackground(
                resumeRate: resumeRate
            ) else {
                return
            }
            lifecycleDiagnostics(
                "background-entered",
                "epoch=\(recovery.epoch)",
                "route=\(snapshot.route)",
                "resumeRate=\(lifecycleRateField(resumeRate))",
                "enginePhase=\(engine.playbackPhase)"
            )
        case .becameActive:
            guard let recovery =
                    foregroundRecovery.beginForegroundRecovery() else {
                lifecycleDiagnostics(
                    "active-ignored",
                    "reason=no-backgrounded-session",
                    "phase=\(foregroundRecovery.phase)"
                )
                return
            }
            lifecycleDiagnostics(
                "recovery-began",
                "epoch=\(recovery.epoch)",
                "route=\(snapshot.route)",
                "resumeRate=\(lifecycleRateField(recovery.resumeRate))"
            )
            foregroundRecoveryTask = Task { @MainActor [weak self] in
                await self?.recoverAfterForegroundTransition(recovery)
            }
        }
    }

    public func selectAudioTrack(id: Int) {
        guard !stopped,
              engine.audioTracks.contains(where: { $0.id == id }) else {
            return
        }
        engine.selectAudioTrack(index: id)
    }

    /// Changes on the engine's actual session teardown, including subtitle reloads.
    public var audioTapSourceGeneration: UUID { engine.scrubPreviewSourceGeneration }
    public var audioTapSourceTime: Double { engine.sourceTime }

    /// One consumer, explicitly bound to the currently audible selection. The
    /// remote-HLS engine tap currently resolves the default rendition only.
    public func installAudioTap(lossless: Bool = false) async throws -> AsyncStream<HybridPlaybackAudioBuffer> {
        guard !stopped else { throw HybridPlaybackAudioTapError.sessionStopped }
        // The remote-HLS tap follows the live edge on a cumulative reader clock,
        // not the user's delayed/live-DVR audible cursor. Do not identify other audio.
        guard !sourceAdmission.isLiveHLS else {
            throw HybridPlaybackAudioTapError.liveTimelineUnsupported
        }
        let generation = audioTapSourceGeneration
        if sourceAdmission.isConfirmedHLS, !sourceAdmission.requiresAetherHLSVODRemux {
            guard let item = engine.currentAVPlayer?.currentItem else {
                throw HybridPlaybackAudioTapError.sourceUnavailable
            }
            let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
            guard !stopped, generation == audioTapSourceGeneration,
                  engine.currentAVPlayer?.currentItem === item else {
                throw HybridPlaybackAudioTapError.sourceChanged
            }
            if let group {
                guard let selected = item.currentMediaSelection.selectedMediaOption(in: group) else {
                    throw HybridPlaybackAudioTapError.selectedAudioUnsupported
                }
                if group.options.count > 1, selected !== group.defaultOption {
                    throw HybridPlaybackAudioTapError.selectedAudioUnsupported
                }
            }
        }
        try Task.checkCancellation()
        let stream = engine.installAudioTap(lossless: lossless)
        guard engine.audioTapHasDeliverySource else {
            engine.removeAudioTap()
            throw HybridPlaybackAudioTapError.noDeliverySource
        }
        return stream
    }

    public func removeAudioTap() { engine.removeAudioTap() }

    /// Availability of stills from playback's resident cache, without another
    /// source connection. Individual frames can remain unavailable.
    public var supportsCacheBackedStills: Bool {
        !stopped && engine.supportsCacheBackedStills
    }

    /// Uses the engine's session timeline, matching seek(to:). Unavailable
    /// cache material or an unsupported route returns nil without another read.
    public func scrubThumbnail(atSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard !stopped else { return nil }
        return await engine.scrubThumbnail(atSeconds: seconds, maxWidth: maxWidth)
    }

    /// Cache-backed sources share playback's cursor. Other providers retain
    /// their bounded input. Stop and audio-selection changes revoke the work.
    public func fingerprintAudioPlan(for region: HybridFingerprintAudioRegion) throws -> HybridFingerprintAudioPlan {
        try HybridFingerprintAudioProviderResolver.resolve(admission: sourceAdmission, region: region)
    }

    public func fingerprintAudio(
        request fingerprintRequest: HybridFingerprintAudioRequest,
        audioSelection: HybridRemoteHLSAudioSelection? = nil,
        onProgress: HybridFingerprintAudioProgressHandler? = nil
    ) async throws -> HybridFingerprintAudioBatch {
        try await performFingerprintOperation {
            try await self.prepareFingerprintAudio(
                request: fingerprintRequest,
                audioSelection: audioSelection,
                onProgress: onProgress
            )
        }
    }

    private func prepareFingerprintAudio(
        request fingerprintRequest: HybridFingerprintAudioRequest,
        audioSelection: HybridRemoteHLSAudioSelection?,
        onProgress: HybridFingerprintAudioProgressHandler?
    ) async throws -> HybridFingerprintAudioBatch {
        guard !stopped else {
            throw HybridFingerprintAudioError.sessionStopped
        }

        try fingerprintRequest.validate()
        let plan = try fingerprintAudioPlan(for: fingerprintRequest.region)
        try await waitForFingerprintMaterial(fingerprintRequest, plan: plan, onProgress: onProgress)
        let provider = plan.provider
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_PROVIDER "
                + "session=\(diagnosticsID) "
                + "provider=\(provider.rawValue) timing=\(plan.timing.rawValue) "
                + "range=\(String(format: "%.3f", fingerprintRequest.sourceRange.lowerBound))..."
                + "\(String(format: "%.3f", fingerprintRequest.sourceRange.upperBound))"
        )

        let batch: HybridFingerprintAudioBatch
        if let onProgress {
            await onProgress(HybridFingerprintAudioProgress(
                provider: provider, phase: .preparing,
                sourceTime: fingerprintRequest.sourceRange.lowerBound,
                sourceRange: fingerprintRequest.sourceRange,
                fraction: 0, elapsedSeconds: 0
            ))
        }
        do {
            switch provider {
            case .segmentCache:
                let cached = try await engine.fingerprintAudio(
                    in: fingerprintRequest.sourceRange,
                    timeoutSeconds: fingerprintRequest.deadlineSeconds
                )
                try Task.checkCancellation()
                batch = HybridFingerprintAudioBatch(
                    buffers: cached.buffers.map {
                        HybridFingerprintAudioBuffer(
                            buffer: $0.buffer,
                            sourceTime: $0.sourceTime,
                            discontinuity: $0.discontinuity
                        )
                    },
                    sourceRange: cached.sourceRange,
                    provider: .segmentCache,
                    segmentCount: cached.segmentCount,
                    preparationSeconds: cached.cacheWaitSeconds,
                    cacheWaitSeconds: cached.cacheWaitSeconds,
                    decodeSeconds: cached.decodeSeconds
                )
                if let onProgress {
                    await onProgress(HybridFingerprintAudioProgress(
                        provider: .segmentCache, phase: .decoding,
                        sourceTime: fingerprintRequest.sourceRange.upperBound,
                        sourceRange: fingerprintRequest.sourceRange,
                        fraction: 1,
                        elapsedSeconds: cached.cacheWaitSeconds + cached.decodeSeconds
                    ))
                }
            case .independentRemoteHLS:
                let selection: HybridRemoteHLSAudioSelection
                if let audioSelection {
                    selection = audioSelection
                } else {
                    selection = try await nativeHLSAudioSelection()
                }
                let source = HybridIndependentFingerprintAudioSource.remoteHLS(
                    HybridRemoteHLSAudioRequest(
                        url: request.url,
                        httpHeaders: request.httpHeaders,
                        selection: selection
                    )
                )
                batch = try await HybridFingerprintWork.run {
                    try await HybridIndependentFingerprintAudio.decode(
                        source: source,
                        range: fingerprintRequest.sourceRange,
                        deadlineSeconds: fingerprintRequest.deadlineSeconds,
                        onProgress: onProgress
                    )
                }
            case .independentDemuxer:
                let selectedTrack = engine.audioTracks.first {
                    $0.id == engine.activeAudioTrackIndex
                }
                let source = HybridIndependentFingerprintAudioSource.demuxer(
                    url: request.url,
                    httpHeaders: request.httpHeaders,
                    selectedTrack: selectedTrack
                )
                batch = try await HybridFingerprintWork.run {
                    try await HybridIndependentFingerprintAudio.decode(
                        source: source,
                        range: fingerprintRequest.sourceRange,
                        deadlineSeconds: fingerprintRequest.deadlineSeconds,
                        onProgress: onProgress
                    )
                }
            }
        } catch let error as AetherFingerprintAudioError {
            HybridDiagnosticEmitter.emit("SYNCNEXT_HYBRID_FINGERPRINT_CACHE event=failed error=\(error)")
            switch error {
            case .invalidRange:
                throw HybridFingerprintAudioError.invalidRange
            case .loopbackVODRequired, .sourceAxisUnavailable:
                throw HybridFingerprintAudioError.sourceUnavailable
            case .audioTrackUnavailable:
                throw HybridFingerprintAudioError.audioTrackUnavailable
            case .segmentUnavailable, .segmentTimelineUnavailable, .segmentDecodeFailed:
                throw HybridFingerprintAudioError.sourceUnavailable
            case .discontinuousRange:
                throw HybridFingerprintAudioError.discontinuousRange
            case .incompleteRange:
                throw HybridFingerprintAudioError.incompleteRange
            case .sessionChanged:
                throw HybridFingerprintAudioError.sessionChanged
            }
        }
        guard !stopped else {
            throw HybridFingerprintAudioError.sessionStopped
        }

        return batch
    }

    /// Uses the existing PCM/file fingerprint entrypoints. Only a material
    /// acquisition failure activates the explicitly authorized extractor fallback.
    public func fingerprintArtifact(
        request fingerprintRequest: HybridFingerprintAudioRequest,
        label: String,
        onProgress: HybridFingerprintAudioProgressHandler? = nil
    ) async throws -> RepeatedSegmentFingerprintArtifact {
        let artifact = try await performFingerprintOperation {
            try await self.prepareFingerprintArtifact(
                request: fingerprintRequest, label: label, onProgress: onProgress
            )
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_ARTIFACT session=\(diagnosticsID) event=completed "
                + "region=\(fingerprintRequest.region) sourceStart=\(artifact.sourceStartSeconds) "
                + "frames=\(artifact.fingerprints.count)"
        )
        return artifact
    }

    private func prepareFingerprintArtifact(
        request fingerprintRequest: HybridFingerprintAudioRequest,
        label: String,
        onProgress: HybridFingerprintAudioProgressHandler?
    ) async throws -> RepeatedSegmentFingerprintArtifact {
        guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
        try fingerprintRequest.validate()
        // Waiting for playback to reach the tail is not active material work
        // and must not consume the acquisition/analysis deadline.
        let plan = try fingerprintAudioPlan(for: fingerprintRequest.region)
        try await waitForFingerprintMaterial(fingerprintRequest, plan: plan, onProgress: onProgress)
        let deadline = ProcessInfo.processInfo.systemUptime + fingerprintRequest.deadlineSeconds
        let selectedTrack = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        let selection = sourceAdmission.isConfirmedHLS ? try await nativeHLSAudioSelection() : nil
        let batch: HybridFingerprintAudioBatch
        do {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HybridFingerprintAudioError.deadlineExceeded }
            batch = try await prepareFingerprintAudio(
                request: HybridFingerprintAudioRequest(
                    sourceRange: fingerprintRequest.sourceRange,
                    deadlineSeconds: remaining, region: fingerprintRequest.region
                ),
                audioSelection: selection, onProgress: onProgress
            )
        } catch let error as HybridFingerprintAudioError
            where error.canUseIntroAudioExtraction
                && !HybridFingerprintAudioProviderResolver.requiresPlaybackCache(admission: sourceAdmission) {
            try Task.checkCancellation()
            guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HybridFingerprintAudioError.deadlineExceeded
            }
            let extraction = HybridIntroAudioExtractionRequest(
                url: request.url, httpHeaders: request.httpHeaders,
                sourceRange: fingerprintRequest.sourceRange,
                outputURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aac"),
                audioSelection: selection, selectedTrack: selectedTrack
            )
            HybridDiagnosticEmitter.emit("SYNCNEXT_HYBRID_FINGERPRINT_FALLBACK event=started primaryError=\(error)")
            do {
                let artifact = try await HybridFingerprintWork.run {
                    defer {
                        if FileManager.default.fileExists(atPath: extraction.outputURL.path) {
                            try? FileManager.default.removeItem(at: extraction.outputURL)
                        }
                    }
                    let audio = try await HybridIntroAudioExtractor.extract(request: extraction)
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw HybridFingerprintAudioError.deadlineExceeded
                    }
                    let range = extraction.sourceRange
                    // Same leading/trailing coverage tolerances as the PCM provider.
                    guard audio.sourceStartSeconds <= range.lowerBound + 0.05,
                          audio.sourceStartSeconds + audio.sourceDuration >= range.upperBound - 0.25 else {
                        throw HybridFingerprintAudioError.incompleteRange
                    }
                    return try RepeatedSegmentFingerprint.compute(
                        audioFileURL: audio.url, label: label, sourceStartSeconds: audio.sourceStartSeconds
                    )
                }
                try Task.checkCancellation()
                guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
                HybridDiagnosticEmitter.emit("SYNCNEXT_HYBRID_FINGERPRINT_FALLBACK event=completed")
                return artifact
            } catch {
                HybridDiagnosticEmitter.emit("SYNCNEXT_HYBRID_FINGERPRINT_FALLBACK event=failed error=\(error)")
                throw error
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw HybridFingerprintAudioError.deadlineExceeded
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_PCM provider=\(batch.provider.rawValue) segments=\(batch.segmentCount) "
                + "preparationSeconds=\(batch.preparationSeconds) cacheWaitSeconds=\(batch.cacheWaitSeconds) decodeSeconds=\(batch.decodeSeconds)"
        )
        return try await HybridFingerprintWork.run {
            try RepeatedSegmentFingerprint.compute(audioBatch: batch, label: label)
        }
    }

    private func waitForFingerprintMaterial(
        _ request: HybridFingerprintAudioRequest, plan: HybridFingerprintAudioPlan,
        onProgress: HybridFingerprintAudioProgressHandler?
    ) async throws {
        func isReady(_ time: Double) -> Bool {
            plan.isReady(
                for: request.sourceRange, playbackTime: time,
                isSeeking: nativeSeekInFlight || engine.isSeeking || hasPendingProxyNavigation
            )
        }
        guard !isReady(snapshot.currentTime) else { return }
        if let onProgress {
            await onProgress(HybridFingerprintAudioProgress(
                provider: plan.provider, phase: .waitingForPlayback,
                sourceTime: snapshot.currentTime, sourceRange: request.sourceRange,
                fraction: 0, elapsedSeconds: 0
            ))
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_MATERIAL session=\(diagnosticsID) event=waiting "
                + "region=\(request.region) sourceStart=\(request.sourceRange.lowerBound) timing=\(plan.timing.rawValue) policy=playback-cache"
        )
        for await state in $snapshot.values {
            try Task.checkCancellation()
            guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
            if case .failed = state.phase { throw HybridFingerprintAudioError.sourceUnavailable }
            if isReady(state.currentTime) {
                HybridDiagnosticEmitter.emit(
                    "SYNCNEXT_HYBRID_FINGERPRINT_MATERIAL session=\(diagnosticsID) event=ready "
                        + "region=\(request.region) sourceTime=\(state.currentTime) policy=playback-cache"
                )
                return
            }
        }
        try Task.checkCancellation()
        throw HybridFingerprintAudioError.sessionStopped
    }

    private func performFingerprintOperation<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
        let revision = audioSelectionRevision
        let identifier = UUID()
        let worker = Task { @MainActor in try await operation() }
        fingerprintCancellations[identifier] = { worker.cancel() }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_WORK session=\(diagnosticsID) event=started operation=\(identifier)"
        )
        defer {
            fingerprintCancellations.removeValue(forKey: identifier)
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_FINGERPRINT_WORK session=\(diagnosticsID) event=finished operation=\(identifier)"
            )
        }
        do {
            let result = try await withTaskCancellationHandler {
                let value = try await worker.value
                try Task.checkCancellation()
                return value
            } onCancel: {
                worker.cancel()
            }
            guard !stopped else { throw HybridFingerprintAudioError.sessionStopped }
            guard revision == audioSelectionRevision else { throw HybridFingerprintAudioError.sessionChanged }
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if stopped { throw HybridFingerprintAudioError.sessionStopped }
            if revision != audioSelectionRevision { throw HybridFingerprintAudioError.sessionChanged }
            throw error
        }
    }

    private func cancelFingerprintOperations(reason: String) {
        let cancellations = fingerprintCancellations.values
        fingerprintCancellations.removeAll()
        cancellations.forEach { $0() }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_WORK session=\(diagnosticsID) event=cancelled "
                + "reason=\(reason) count=\(cancellations.count)"
        )
    }

    public func selectSubtitleTrack(id: Int?, origin: HybridSubtitleSelectionOrigin = .programmatic) {
        guard !stopped else {
            return
        }
        let selected: HybridMediaTrack?
        if let id {
            guard let track = Self.mapTracks(engine.subtitleTracks, kind: .subtitle)
                .first(where: { $0.id == id }) else {
                return
            }
            selected = track
        } else {
            selected = nil
        }
        // Revoke the host's automatic-selection authority before the engine
        // publishes any synchronous selection or catalog updates.
        if case .user = origin {
            userSubtitleSelectionSubject.send(selected)
        }
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    public func stop() {
        guard !stopped else {
            return
        }
        stopped = true
        cancelFingerprintOperations(reason: "session-stopped")
        startupDiagnostics.stop()
        logMediaSessionStop(event: "stop.begin")
        vodBufferPolicy = nil
        nativeSeekGeneration &+= 1
        replayTask?.cancel()
        replayTask = nil
        foregroundRecovery.stop()
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        proxyNavigationTasks.values.forEach { $0.cancel() }
        proxyNavigationTasks.removeAll()
        detach()
        engine.stop()
        manifestFallbackServer?.stop()
        manifestFallbackServer = nil
        proxyContext?.player.pause()
        proxyContext?.timeline.stop()
        eventContinuation.finish()
        logMediaSessionStop(event: "stop.accepted")
    }

    private func logMediaSessionStop(event: String) {
        HybridDiagnosticEmitter.emit(
            "MEDIA_SESSION event=\(event) session=\(diagnosticsID)"
                + " sourceID=\(HybridPlaybackPlan.sourceID(request.url))"
                + " uptimeMs=\(Int64(ProcessInfo.processInfo.systemUptime * 1_000))"
                + " route=\(snapshot.route)"
        )
    }

    #if DEBUG
    /// Counts retained decoded subtitle storage without copying image pixels.
    /// Pixel bytes are an estimate from CGImage layout, not a footprint claim.
    /// Past source time alone is not an eviction rule: offsets and seeks still
    /// require the subtitle's authored presentation window.
    public var memoryObservation: (counters: [String: Int], selectedSubtitleCodec: String?) {
        var images: [ObjectIdentifier: (bytes: Int, encodedBytes: Int?, pastOnly: Bool)] = [:]
        var bitmaps = 0, texts = 0, richTexts = 0, textBytes = 0
        let playhead = engine.sourceTime
        for cue in engine.subtitleCues {
            switch cue.body {
            case .image(let image):
                bitmaps += 1
                let key = ObjectIdentifier(image.cgImage)
                let previous = images[key]
                images[key] = (image.cgImage.bytesPerRow * image.cgImage.height,
                               image.encodedBackingBytes,
                               (previous?.pastOnly ?? true) && cue.endTime < playhead)
            case .text(let text):
                texts += 1; textBytes += text.utf8.count
            case .richText(let runs):
                richTexts += 1; textBytes += runs.reduce(0) { $0 + $1.text.utf8.count }
            }
        }
        let counters = [
            "subtitleCueCount": engine.subtitleCues.count,
            "subtitleBitmapCueCount": bitmaps, "subtitleUniqueBitmapCount": images.count,
            "subtitleBitmapBytesEstimate": images.values.reduce(0) { $0 + $1.bytes },
            "subtitlePastBitmapBytesEstimate": images.values.filter(\.pastOnly).reduce(0) { $0 + $1.bytes },
            "subtitleEncodedBackingBytes": images.values.reduce(0) { $0 + ($1.encodedBytes ?? 0) },
            "subtitleEncodedBitmapCount": images.values.filter { $0.encodedBytes != nil }.count,
            "subtitleTextCueCount": texts, "subtitleRichTextCueCount": richTexts,
            "subtitleTextUTF8Bytes": textBytes,
        ]
        let codec = snapshot.subtitleTracks.first { $0.id == snapshot.selectedSubtitleTrackID }?.codec
        return (counters, codec)
    }
    #endif

    deinit {
        fingerprintCancellations.values.forEach { $0() }
        manifestFallbackServer?.stop()
        foregroundRecoveryTask?.cancel()
        replayTask?.cancel()
        proxyNavigationTasks.values.forEach { $0.cancel() }
        eventContinuation.finish()
        proxyRateObservation?.invalidate()
    }

    private func installObservers() {
        engine.$subtitleCues
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateSubtitleOverlay(cuesChanged: true)
                }
            }
            .store(in: &observations)

        engine.clock.$sourceTime
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateSubtitleOverlay()
                }
            }
            .store(in: &observations)

        engine.$currentAVPlayer
            .sink { [weak self] player in
                Task { @MainActor in
                    self?.applyAetherPlayer(player)
                }
            }
            .store(in: &observations)

        engine.$playbackPhase
            .sink { [weak self] phase in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.applyAetherMaterial()
                    if self.snapshot.route == .nativeAVPlayer {
                        self.publishSnapshot()
                    }
                }
            }
            .store(in: &observations)

        engine.$duration
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.snapshot.route == .nativeAVPlayer else {
                        return
                    }
                    self.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.clock.$currentTime
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.snapshot.route == .nativeAVPlayer else {
                        return
                    }
                    self.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.clock.$bufferedPosition
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyAetherMaterial()
                    self?.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.$sourceVideoWidth
            .combineLatest(engine.$sourceVideoHeight)
            .combineLatest(engine.$sourceVideoBitrate)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.diagnostics.$liveTelemetry
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.$audioTracks
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshMenusAndSnapshot()
                }
            }
            .store(in: &observations)

        engine.$subtitleTracks
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshMenusAndSnapshot()
                }
            }
            .store(in: &observations)

        engine.$activeAudioTrackIndex
            .sink { [weak self] selectedID in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    let selectionChanged =
                        self.snapshot.selectedAudioTrackID != selectedID
                    if selectionChanged {
                        let previousRevision = self.audioSelectionRevision
                        self.audioSelectionRevision &+= 1
                        self.cancelFingerprintOperations(reason: "audio-selection-changed")
                        HybridDiagnosticEmitter.emit(
                            "SYNCNEXT_HYBRID_AUDIO_SELECTION "
                                + "session=\(self.diagnosticsID) "
                                + "event=revision-changed "
                                + "source=activeAudioTrackIndex "
                                + "oldRevision=\(previousRevision) "
                                + "newRevision=\(self.audioSelectionRevision) "
                                + "snapshotTrack=\(self.snapshot.selectedAudioTrackID.map(String.init) ?? "nil") "
                                + "engineTrack=\(selectedID.map(String.init) ?? "nil") "
                                + "time=\(String(format: "%.3f", self.engine.currentTime)) "
                                + "item=\(self.nativePlayerItemIdentity())"
                        )
                    }
                    self.refreshMenusAndSnapshot()
                }
            }
            .store(in: &observations)

        engine.$activeSubtitleTrackIndex
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshMenusAndSnapshot()
                }
            }
            .store(in: &observations)

        installProxyRateObserver()
    }

    private func installProxyRateObserver() {
        if let proxyContext {
            proxyRateObservation = proxyContext.player.observe(
                \.rate,
                options: [.new]
            ) { [weak self] _, change in
                guard let rate = change.newValue else {
                    return
                }
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.proxyDiagnostics(
                        "rate-observed",
                        "rate=\(rate)",
                        "enginePhase=\(self.engine.playbackPhase)",
                        "engineTime=\(self.engine.currentTime)",
                        "proxyTime=\(proxyContext.player.currentTime().seconds)",
                        "requestedRate=\(self.requestedRate)"
                    )
                    guard self.snapshot.route == .avKitProxy else {
                        return
                    }
                    guard proxyContext.player.rate == rate else {
                        self.proxyDiagnostics(
                            "rate-forward-ignored",
                            "reason=stale-client-observation",
                            "rate=\(rate)"
                        )
                        return
                    }
                    let clientIsWaiting =
                        proxyContext.player.timeControlStatus
                        == .waitingToPlayAtSpecifiedRate
                    let hasPendingNavigation = self.hasPendingProxyNavigation
                    let hasPendingClientSeek =
                        self.pendingProxyClientSeekGeneration
                            == proxyContext.timeline.state.seekGeneration
                    guard HybridHLSProxyRateObservationPolicy.shouldAccept(
                        rate: rate,
                        clientIsWaiting: clientIsWaiting,
                        hasPendingNavigation: hasPendingNavigation,
                        hasPendingClientSeek: hasPendingClientSeek
                    ) else {
                        self.proxyDiagnostics(
                            "rate-forward-ignored",
                            "reason="
                                + (hasPendingClientSeek
                                    ? "client-seek-in-flight"
                                    : hasPendingNavigation
                                        ? "seek-in-flight"
                                        : "waiting-to-play"),
                            "rate=\(rate)",
                            "serverRate="
                                + "\(proxyContext.timeline.state.rate)"
                        )
                        return
                    }
                    proxyContext.timeline.acceptClientRate(rate)
                }
            }
        }

        // Deliberately do not translate AVPlayerItem.timeJumpedNotification
        // into an Aether seek. Proxy initialization and programmatic seeks
        // emit that notification too. AVKit's navigation delegate above is
        // the user-intent boundary.
    }

    private func applyAetherPlayer(_ player: AVPlayer?) {
        guard !stopped else {
            return
        }
        let oldRoute = snapshot.route
        let newRoute: HybridPlaybackRoute
        if let player, !forceAVKitProxy {
            let newIdentity = ObjectIdentifier(player)
            lastNativePlayerIdentity = newIdentity
            avPlayer = player
            newRoute = .nativeAVPlayer
        } else if let proxyContext {
            lastNativePlayerIdentity = nil
            avPlayer = proxyContext.player
            newRoute = .avKitProxy
        } else {
            // A native session owns no Proxy Server. A transient nil player
            // publication during teardown or item replacement must not invent
            // a proxy route that was never constructed.
            return
        }
        if newRoute != .avKitProxy {
            proxyNavigationTasks.values.forEach { $0.cancel() }
            proxyNavigationTasks.removeAll()
        }
        if attachedController?.player !== avPlayer {
            attachedController?.player = avPlayer
        }
        configureVODBufferPolicy()
        do {
            try updateSurfaceAttachment(for: newRoute)
        } catch {
            eventContinuation.yield(
                .snapshot(
                    HybridPlaybackSnapshot(
                        phase: .failed(error.localizedDescription),
                        route: newRoute,
                        currentTime: engine.currentTime,
                        duration:
                            HybridNativeSnapshotDurationPolicy.duration(
                                admission: sourceAdmission,
                                engineDuration: engine.duration
                            ),
                        rate: requestedRate,
                        selectedAudioTrackID:
                            engine.activeAudioTrackIndex,
                        selectedSubtitleTrackID:
                            engine.activeSubtitleTrackIndex,
                        audioTracks:
                            Self.mapTracks(engine.audioTracks, kind: .audio),
                        subtitleTracks:
                            Self.mapTracks(
                                engine.subtitleTracks,
                                kind: .subtitle
                            ),
                        diagnostics: Self.makeDiagnostics(engine: engine)
                    )
                )
            )
        }
        publishSnapshot()
        if oldRoute != newRoute {
            eventContinuation.yield(.playerBindingChanged(newRoute))
        }
    }

    private func updateSurfaceAttachment(
        for route: HybridPlaybackRoute
    ) throws {
        guard let controller = attachedController else {
            if route == .nativeAVPlayer {
                engine.unbind(view: surface)
            } else {
                engine.bind(view: surface)
            }
            return
        }
        switch route {
        case .nativeAVPlayer:
            surface.removeFromSuperview()
            engine.unbind(view: surface)
        case .avKitProxy:
            guard let overlay = controller.contentOverlayView else {
                throw HybridPlaybackError.avKitOverlayUnavailable
            }
            if surface.superview !== overlay {
                surface.removeFromSuperview()
                surface.translatesAutoresizingMaskIntoConstraints = false
                surface.isUserInteractionEnabled = false
                overlay.insertSubview(surface, at: 0)
                NSLayoutConstraint.activate([
                    surface.leadingAnchor.constraint(
                        equalTo: overlay.leadingAnchor
                    ),
                    surface.trailingAnchor.constraint(
                        equalTo: overlay.trailingAnchor
                    ),
                    surface.topAnchor.constraint(
                        equalTo: overlay.topAnchor
                    ),
                    surface.bottomAnchor.constraint(
                        equalTo: overlay.bottomAnchor
                    ),
                ])
            }
            engine.bind(view: surface)
        }
        guard let overlay = controller.contentOverlayView else {
            throw HybridPlaybackError.avKitOverlayUnavailable
        }
        if subtitleOverlay.superview !== overlay {
            subtitleOverlay.removeFromSuperview()
            subtitleOverlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(subtitleOverlay)
            NSLayoutConstraint.activate([
                subtitleOverlay.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                subtitleOverlay.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                subtitleOverlay.topAnchor.constraint(equalTo: overlay.topAnchor),
                subtitleOverlay.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        updateSubtitleOverlay(cuesChanged: true)
    }

    private func updateSubtitleOverlay(cuesChanged: Bool = false) {
        subtitleOverlay.update(
            cues: engine.subtitleCues,
            sourceTime: engine.sourceTime,
            videoSize: CGSize(
                width: Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio,
                height: Double(engine.sourceVideoHeight)
            ),
            cuesChanged: cuesChanged
        )
    }

    private func applyAetherMaterial() {
        guard snapshot.route == .avKitProxy else {
            return
        }
        let supplyPhase: HybridHLSProxySupplyPhase
        switch (engine.playbackPhase, endDisposition) {
        case (.error(let message), _):
            supplyPhase = .failed(message)
        case (_, .completed):
            supplyPhase = .ended
        case (_, .parked):
            supplyPhase = .flowing
        case (.loading, _), (.rebuffering, _), (.stalled, _):
            // Buffer/readiness failures are valid Aether -> Server state.
            // They withhold HLS material and project waitingToPlay without
            // letting Aether replace the Server's rate, seek, or playhead.
            // A seek still has a separate Server-owned pending gate from the
            // request until the matching Aether response.
            supplyPhase = .waiting
        case (.ended, _):
            supplyPhase = .ended
        case (.idle, _), (.playing, _), (.paused, _), (.seeking, _):
            // These Aether transport states cannot drive the authoritative
            // HLS timeline. They are consequences of Server commands.
            supplyPhase = .flowing
        }
        let effectiveBufferedThrough =
            HybridHLSProxyMaterialPolicy.bufferedThrough(
                bufferedPosition: engine.bufferedPosition,
                renderedSourceTime: engine.sourceTime
            )
        let material = HybridHLSProxyMaterial(
            phase: supplyPhase,
            bufferedThrough: effectiveBufferedThrough
        )
        proxyTimeline.update(material: material)
        let shouldLog: Bool
        if let previous = lastLoggedHLSMaterial {
            shouldLog = previous.phase != material.phase
                || abs(
                    previous.bufferedThrough
                        - material.bufferedThrough
                ) >= 1
        } else {
            shouldLog = true
        }
        guard shouldLog else {
            return
        }
        lastLoggedHLSMaterial = material
        proxyDiagnostics(
            "hls-material-updated",
            "enginePhase=\(engine.playbackPhase)",
            "supplyPhase=\(supplyPhase)",
            "bufferedPosition=\(engine.bufferedPosition)",
            "effectiveBufferedThrough=\(effectiveBufferedThrough)",
            "engineTime=\(engine.currentTime)",
            "engineSourceTime=\(engine.sourceTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)"
        )
    }

    private func handleProxyServerEvent(
        _ event: HybridHLSTimelineEvent
    ) {
        guard !stopped,
              snapshot.route == .avKitProxy else {
            return
        }
        switch event {
        case .stateChanged(let state):
            if state.phase == .ended, endDisposition != .completed {
                endDisposition = .completed
                engine.pause()
                proxyPlayer.pause()
            }
            publishSnapshot()
        case .transportRateChanged(let rate, _):
            forwardRateToAether(
                rate,
                reason: "hls-server-rate-event"
            )
            publishSnapshot()
        case .seekRequested(let generation, let target):
            let context = pendingServerSeekContext
            pendingServerSeekContext = nil
            let oldTime = context?.oldTime
                ?? proxyTimeline.state.currentTime
            let origin = context?.origin ?? .programmatic
            let navigation = HybridProxyNavigation(
                generation: generation,
                oldTime: oldTime,
                targetTime: target,
                origin: origin,
                intent: context?.intent ?? .position
            )
            proxyDiagnostics(
                "server-seek-projected",
                "generation=\(generation)",
                "origin=\(origin)",
                "target=\(target)"
            )
            forwardProxySeekToAether(navigation)
            publishSnapshot()
        }
    }

    private func requestProxyAuthoritySeek(
        to seconds: Double,
        reason: String
    ) {
        let target = max(0, min(seconds, proxyDuration))
        let generation = proxyTimeline.state.seekGeneration
        pendingProxyClientSeekGeneration = generation
        proxyDiagnostics(
            "seek-dispatched",
            "reason=\(reason)",
            "generation=\(generation)",
            "requested=\(seconds)",
            "target=\(target)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)",
            "serverGeneration=\(proxyTimeline.state.seekGeneration)"
        )
        // Forward the same authoritative Server operation to the HLS client.
        // AVPlayer owns its own cancellation semantics; Hybrid adds none.
        proxyPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(
                seconds:
                    HybridHLSProxyPlaylist.segmentDuration / 2,
                preferredTimescale: 600
            ),
            toleranceAfter: CMTime(
                seconds:
                    HybridHLSProxyPlaylist.segmentDuration / 2,
                preferredTimescale: 600
            )
        ) { [weak self] finished in
            Task { @MainActor in
                guard let self else {
                    return
                }
                if finished {
                    self.markAVKitProxyClientSeekCompleted(
                        generation: generation
                    )
                } else if self.pendingProxyClientSeekGeneration == generation {
                    self.pendingProxyClientSeekGeneration = nil
                }
                self.proxyDiagnostics(
                    "seek-completed",
                    "generation=\(generation)",
                    "finished=\(finished)",
                    "target=\(target)",
                    "engineTime=\(self.engine.currentTime)",
                    "proxyTime=\(self.proxyPlayer.currentTime().seconds)"
                )
            }
        }
    }

    private func markAVKitProxyClientSeekCompleted(
        generation: UInt64
    ) {
        completedProxyClientSeekGenerations.insert(generation)
        if completedProxyClientSeekGenerations.count > 32,
           let oldest = completedProxyClientSeekGenerations.min() {
            completedProxyClientSeekGenerations.remove(oldest)
        }
        guard generation == proxyTimeline.state.seekGeneration else { return }
        if pendingProxyClientSeekGeneration == generation {
            pendingProxyClientSeekGeneration = nil
        }
        // AVPlayer can echo its pre-seek rate after the renderer has already
        // parked. Completion restores only the Server's transport, never the
        // other way around. Older completions cannot touch a newer operation.
        let rate = proxyTimeline.state.rate
        if rate == 0 {
            proxyPlayer.pause()
        } else {
            proxyPlayer.defaultRate = rate
            proxyPlayer.play()
        }
    }

    private func forwardRateToAether(
        _ rate: Float,
        reason: String
    ) {
        proxyDiagnostics(
            "rate-forwarded-to-aether",
            "reason=\(reason)",
            "rate=\(rate)",
            "enginePhaseBefore=\(engine.playbackPhase)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)"
        )
        if rate == 0 {
            engine.pause()
        } else {
            requestedRate = rate
            // A rate arriving during navigation is intent for its landing,
            // not permission to play the renderer at its previous endpoint.
            guard !hasPendingProxyNavigation else { return }
            if needsReplay {
                requestReplay()
                return
            }
            engine.setRate(rate)
            engine.play()
        }
    }

    private func forwardProxySeekToAether(
        _ navigation: HybridProxyNavigation
    ) {
        proxyDiagnostics(
            "navigation-forwarded-to-aether",
            "generation=\(navigation.generation)",
            "origin=\(navigation.origin)",
            "target=\(navigation.targetTime)",
            "transport=seek-without-pause",
            "authoritativeRate=\(proxyTimeline.state.rate)"
        )
        proxyNavigationTasks[navigation.generation] = Task {
            @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.runProxyNavigationSeek(navigation)
            } catch {
                if !Task.isCancelled, !self.stopped,
                   navigation.generation == self.proxyTimeline.state.seekGeneration {
                    self.engine.pause()
                    self.proxyPlayer.pause()
                    self.proxyTimeline.update(
                        material: HybridHLSProxyMaterial(
                            phase: .failed(String(describing: error)),
                            bufferedThrough: self.engine.bufferedPosition
                        )
                    )
                }
                throw error
            }
        }
    }

    private func runProxyNavigationSeek(
        _ navigation: HybridProxyNavigation
    ) async throws {
        proxyDiagnostics(
            "navigation-seek-dispatched",
            "generation=\(navigation.generation)",
            "origin=\(navigation.origin)",
            "target=\(navigation.targetTime)"
        )
        defer { proxyNavigationTasks[navigation.generation] = nil }
        try await HybridSeekTransport.perform(
            engine: engine,
            target: navigation.targetTime,
            intent: navigation.intent,
            isCurrent: {
                !self.stopped && self.snapshot.route == .avKitProxy
                    && navigation.generation == self.proxyTimeline.state.seekGeneration
            },
            acceptLanding: { disposition in
                self.endDisposition = disposition
                let acknowledged = self.proxyTimeline.acknowledgeSeekResponse(
                    generation: navigation.generation
                )
                guard acknowledged else { return .superseded }
                switch disposition {
                case .none:
                    break
                case .parked:
                    self.commandProxyRate(0, reason: "seek-parked-at-end")
                case .completed:
                    self.proxyPlayer.pause()
                    guard self.proxyTimeline.completeSeek(
                        generation: navigation.generation
                    ) else { return .superseded }
                }
                self.proxyDiagnostics(
                    "navigation-landed",
                    "generation=\(navigation.generation)",
                    "target=\(navigation.targetTime)",
                    "intent=\(navigation.intent)",
                    "endDisposition=\(disposition)",
                    "engineTime=\(self.engine.currentTime)",
                    "proxyTime=\(self.proxyTimeline.state.currentTime)",
                    "authoritativeRate=\(self.proxyTimeline.state.rate)"
                )
                return .restoreRate(self.proxyTimeline.state.rate)
            }
        )
        publishSnapshot()
    }

    /// Accepts the operation on the authoritative Server first, then forwards
    /// it unchanged to the HLS client. The Server event forwards it to Aether.
    private func commandProxyRate(
        _ rate: Float,
        reason: String
    ) {
        let previousRate = proxyPlayer.rate
        proxyTimeline.commandRate(rate)
        if rate == 0 {
            proxyPlayer.pause()
        } else {
            proxyPlayer.defaultRate = rate
            proxyPlayer.play()
        }
        proxyDiagnostics(
            "rate-commanded-by-proxy-authority",
            "reason=\(reason)",
            "from=\(previousRate)",
            "to=\(rate)",
            "enginePhase=\(engine.playbackPhase)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)",
            "serverGeneration=\(proxyTimeline.state.seekGeneration)"
        )
    }

    private func proxyDiagnostics(
        _ event: String,
        _ fields: String...
    ) {
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_CONTROL "
                + "session=\(diagnosticsID) "
                + "event=\(event) "
                + fields.joined(separator: " ")
        )
    }

    private func foregroundResumeRate() -> Float? {
        switch snapshot.route {
        case .avKitProxy:
            let rate = proxyTimeline.state.rate
            return rate > 0 ? rate : nil
        case .nativeAVPlayer:
            switch engine.playbackPhase {
            case .loading, .playing, .seeking, .rebuffering, .stalled:
                return max(requestedRate, 1)
            case .idle, .paused, .ended, .error:
                return nil
            }
        }
    }

    private func recoverAfterForegroundTransition(
        _ recovery: HybridForegroundRecoveryCoordinator.Recovery
    ) async {
        do {
            try await engine.reloadAtCurrentPosition()
            try Task.checkCancellation()
            guard !stopped else {
                throw HybridPlaybackError.sessionStopped
            }
            if snapshot.route == .nativeAVPlayer,
               engine.currentAVPlayer == nil {
                throw HybridPlaybackError.foregroundRecoveryFailed(
                    "AetherEngine did not publish a native AVPlayer"
                )
            }
            applyAetherPlayer(engine.currentAVPlayer)
            applyAetherMaterial()
            restoreTransport(after: recovery)
            publishSnapshot()
            guard foregroundRecovery.complete(epoch: recovery.epoch) else {
                lifecycleDiagnostics(
                    "recovery-superseded",
                    "epoch=\(recovery.epoch)"
                )
                return
            }
            lifecycleDiagnostics(
                "recovery-completed",
                "epoch=\(recovery.epoch)",
                "route=\(snapshot.route)",
                "restoredRate=\(lifecycleRateField(recovery.resumeRate))",
                "enginePhase=\(engine.playbackPhase)"
            )
        } catch is CancellationError {
            lifecycleDiagnostics(
                "recovery-cancelled",
                "epoch=\(recovery.epoch)"
            )
        } catch {
            guard foregroundRecovery.fail(epoch: recovery.epoch) else {
                lifecycleDiagnostics(
                    "recovery-failure-superseded",
                    "epoch=\(recovery.epoch)",
                    "errorType=\(String(describing: type(of: error)))"
                )
                return
            }
            let failure: HybridPlaybackError
            if let hybridError = error as? HybridPlaybackError {
                failure = hybridError
            } else {
                failure = .foregroundRecoveryFailed(
                    String(describing: error)
                )
            }
            publishPlaybackFailure(failure)
            let nsError = error as NSError
            lifecycleDiagnostics(
                "recovery-failed",
                "epoch=\(recovery.epoch)",
                "errorType=\(String(describing: type(of: error)))",
                "domain=\(nsError.domain)",
                "code=\(nsError.code)"
            )
        }
        if case .recovering = foregroundRecovery.phase {
            return
        }
        foregroundRecoveryTask = nil
    }

    private func restoreTransport(
        after recovery: HybridForegroundRecoveryCoordinator.Recovery
    ) {
        if needsReplay {
            engine.pause()
            if snapshot.route == .avKitProxy {
                commandProxyRate(0, reason: "foreground-at-end")
            }
            return
        }
        let rate = recovery.resumeRate ?? 0
        if let resumeRate = recovery.resumeRate {
            requestedRate = resumeRate
        }
        switch snapshot.route {
        case .nativeAVPlayer:
            if rate == 0 {
                engine.pause()
            } else {
                engine.play()
                engine.setRate(rate)
            }
        case .avKitProxy:
            commandProxyRate(
                rate,
                reason: "foreground-recovery"
            )
        }
    }

    private func publishPlaybackFailure(
        _ error: HybridPlaybackError
    ) {
        playbackFailure = error
        let failed = HybridPlaybackSnapshot(
            phase: .failed(error.localizedDescription),
            route: snapshot.route,
            currentTime: snapshot.currentTime,
            duration: snapshot.duration,
            rate: 0,
            audioSelectionRevision: snapshot.audioSelectionRevision,
            selectedAudioTrackID: snapshot.selectedAudioTrackID,
            selectedSubtitleTrackID: snapshot.selectedSubtitleTrackID,
            audioTracks: snapshot.audioTracks,
            subtitleTracks: snapshot.subtitleTracks,
            diagnostics: snapshot.diagnostics
        )
        snapshot = failed
        eventContinuation.yield(.snapshot(failed))
    }

    private func lifecycleDiagnostics(
        _ event: String,
        _ fields: String...
    ) {
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_LIFECYCLE "
                + "session=\(diagnosticsID) "
                + "event=\(event) "
                + fields.joined(separator: " ")
        )
    }

    private func lifecycleRateField(_ rate: Float?) -> String {
        guard let rate else {
            return "paused"
        }
        return String(rate)
    }

    private func refreshMenusAndSnapshot() {
        if let controller = attachedController {
            controller.transportBarCustomMenuItems =
                previousCustomMenuItems + makeTrackMenus()
        }
        publishSnapshot()
    }

    private func nativeHLSAudioSelection() async throws -> HybridRemoteHLSAudioSelection {
        if sourceAdmission.requiresAetherHLSVODRemux {
            guard let ordinal = engine.audioTracks.firstIndex(where: { $0.id == engine.activeAudioTrackIndex }) else {
                throw HybridFingerprintAudioError.audioTrackUnavailable
            }
            let track = engine.audioTracks[ordinal]
            return HybridRemoteHLSAudioSelection(
                displayName: track.name, language: track.language, optionOrdinal: ordinal
            )
        }
        guard let item = engine.currentAVPlayer?.currentItem else {
            throw HybridFingerprintAudioError.sourceUnavailable
        }
        let expectedItem = ObjectIdentifier(item)
        let group: AVMediaSelectionGroup?
        do {
            group = try await item.asset.loadMediaSelectionGroup(
                for: .audible
            )
        } catch {
            throw HybridFingerprintAudioError.sourceUnavailable
        }
        guard !stopped else {
            throw HybridFingerprintAudioError.sessionStopped
        }
        guard engine.currentAVPlayer?.currentItem.map(ObjectIdentifier.init)
                == expectedItem else {
            throw HybridFingerprintAudioError.sessionChanged
        }
        guard let group else {
            return HybridRemoteHLSAudioSelection(
                displayName: nil,
                language: nil,
                optionOrdinal: nil
            )
        }
        let selected = item.currentMediaSelection.selectedMediaOption(
            in: group
        )
        let ordinal = selected.flatMap { selected in
            group.options.firstIndex { $0 === selected }
        }
        let selectionSignature = nativeAudibleSelectionSignature(
            item: item,
            group: group
        )
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_AUDIO_SELECTION "
                + "session=\(diagnosticsID) "
                + "event=fingerprint-selection-bound "
                + "item=\(expectedItem) "
                + "selection=\(selectionSignature)"
        )
        return HybridRemoteHLSAudioSelection(
            displayName: selected?.displayName,
            language: selected?.extendedLanguageTag,
            optionOrdinal: ordinal
        )
    }

    private func nativePlayerItemIdentity() -> String {
        engine.currentAVPlayer?.currentItem
            .map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }

    private func nativeAudibleSelectionSignature(
        item: AVPlayerItem,
        group: AVMediaSelectionGroup?
    ) -> String {
        guard let group else {
            return "none"
        }
        guard let selected = item.currentMediaSelection.selectedMediaOption(
            in: group
        ) else {
            return "unselected"
        }
        let ordinal = group.options.firstIndex { $0 === selected }
        let displayName = selected.displayName
            .replacingOccurrences(of: " ", with: "_")
        let language = selected.extendedLanguageTag ?? "nil"
        return "ordinal:\(ordinal.map(String.init) ?? "nil"),name:\(displayName),language:\(language)"
    }

    private func makeTrackMenus() -> [UIMenuElement] {
        var menus: [UIMenuElement] = []
        if !engine.audioTracks.isEmpty {
            let actions = engine.audioTracks.map { track in
                UIAction(
                    title: track.name,
                    state: track.id == engine.activeAudioTrackIndex
                        ? .on
                        : .off
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.selectAudioTrack(id: track.id)
                    }
                }
            }
            menus.append(
                UIMenu(
                    title: "Audio",
                    identifier: UIMenu.Identifier(
                        "com.qoli.SyncnextHybrid.audio"
                    ),
                    options: .singleSelection,
                    children: actions
                )
            )
        }

        if !engine.subtitleTracks.isEmpty {
            var actions: [UIAction] = [
                UIAction(
                    title: "Off",
                    state: engine.activeSubtitleTrackIndex == nil
                        ? .on
                        : .off
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.selectSubtitleTrack(id: nil, origin: .user)
                    }
                },
            ]
            actions.append(
                contentsOf: engine.subtitleTracks.map { track in
                    UIAction(
                        title: track.name,
                        state: track.id
                            == engine.activeSubtitleTrackIndex
                            ? .on
                            : .off
                    ) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.selectSubtitleTrack(id: track.id, origin: .user)
                        }
                    }
                }
            )
            menus.append(
                UIMenu(
                    title: "Subtitles",
                    image: UIImage(systemName: "captions.bubble"),
                    identifier: UIMenu.Identifier(
                        "com.qoli.SyncnextHybrid.subtitles"
                    ),
                    options: .singleSelection,
                    children: actions
                )
            )
        }
        return menus
    }

    private func publishSnapshot() {
        guard !stopped, playbackFailure == nil else {
            return
        }
        let route: HybridPlaybackRoute
        if let proxyContext,
           avPlayer === proxyContext.player {
            route = .avKitProxy
        } else {
            route = .nativeAVPlayer
        }
        let updated = Self.makeSnapshot(
            engine: engine,
            route: route,
            proxyState: proxyContext?.timeline.state,
            sourceAdmission: sourceAdmission,
            nativeRate: requestedRate,
            audioSelectionRevision: audioSelectionRevision,
            endDisposition: endDisposition
        )
        guard updated != snapshot else {
            return
        }
        snapshot = updated
        eventContinuation.yield(.snapshot(updated))
    }

    private static func makeSnapshot(
        engine: AetherEngine,
        route: HybridPlaybackRoute,
        proxyState: HybridHLSTimelineState?,
        sourceAdmission: HybridRemoteSourceAdmission,
        nativeRate: Float,
        audioSelectionRevision: UInt64,
        endDisposition: HybridSeekEndDisposition = .none
    ) -> HybridPlaybackSnapshot {
        let phase: HybridPlaybackPhase
        let currentTime: Double
        let duration: Double
        let rate: Float
        switch route {
        case .nativeAVPlayer:
            duration = HybridNativeSnapshotDurationPolicy.duration(
                admission: sourceAdmission,
                engineDuration: engine.duration
            )
            switch (engine.playbackPhase, endDisposition) {
            case (.error(let message), _):
                phase = .failed(message)
                currentTime = engine.currentTime
                rate = 0
            case (_, .none):
                phase = mapPhase(engine.playbackPhase)
                currentTime = engine.currentTime
                rate = nativeRate
            case (_, .parked):
                phase = .paused
                currentTime = engine.currentTime
                rate = 0
            case (_, .completed):
                phase = .ended
                currentTime = duration
                rate = 0
            }
        case .avKitProxy:
            guard let proxyState else {
                preconditionFailure(
                    "AVKit Proxy snapshot requires a Proxy Server state"
                )
            }
            phase = proxyState.phase
            currentTime = proxyState.currentTime
            duration = proxyState.duration
            rate = proxyState.rate
        }
        return HybridPlaybackSnapshot(
            phase: phase,
            route: route,
            currentTime: currentTime,
            duration: duration,
            rate: rate,
            audioSelectionRevision: audioSelectionRevision,
            selectedAudioTrackID: engine.activeAudioTrackIndex,
            selectedSubtitleTrackID: engine.activeSubtitleTrackIndex,
            audioTracks: mapTracks(engine.audioTracks, kind: .audio),
            subtitleTracks: mapTracks(
                engine.subtitleTracks,
                kind: .subtitle
            ),
            diagnostics: makeDiagnostics(engine: engine)
        )
    }

    private static func makeDiagnostics(
        engine: AetherEngine
    ) -> HybridPlaybackDiagnostics {
        HybridPlaybackDiagnostics(
            sourceVideoWidth: engine.sourceVideoWidth,
            sourceVideoHeight: engine.sourceVideoHeight,
            averageBitrateMbps: engine.liveTelemetry?.averageBitrateMbps,
            sourceVideoBitrate: engine.sourceVideoBitrate,
            bufferedPosition: engine.bufferedPosition,
            sourceTime: engine.sourceTime
        )
    }

    private static func mapPhase(
        _ phase: PlaybackPhase
    ) -> HybridPlaybackPhase {
        switch phase {
        case .idle:
            .idle
        case .loading:
            .loading
        case .playing:
            .playing
        case .paused:
            .paused
        case .seeking:
            .seeking
        case .rebuffering:
            .rebuffering
        case .stalled:
            .stalled
        case .ended:
            .ended
        case .error(let message):
            .failed(message)
        }
    }

    private static func mapTracks(
        _ tracks: [TrackInfo],
        kind: HybridMediaTrack.Kind
    ) -> [HybridMediaTrack] {
        tracks.map {
            HybridMediaTrack(
                id: $0.id,
                kind: kind,
                name: $0.name,
                language: $0.language,
                codec: $0.codec,
                channelCount: $0.channels,
                isDefault: $0.isDefault,
                isForced: $0.isForced,
                isHearingImpaired: $0.isHearingImpaired,
                isCommentary: $0.isCommentary,
                isExternal: $0.isExternal
            )
        }
    }

}
#endif
