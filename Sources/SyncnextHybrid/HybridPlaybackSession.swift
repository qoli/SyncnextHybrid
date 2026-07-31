#if os(tvOS)
import AetherEngine
import AVFoundation
import AVKit
import Combine
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

    @Published public private(set) var avPlayer: AVPlayer
    @Published public private(set) var snapshot: HybridPlaybackSnapshot

    public var hlsProxyServerObservation:
        HybridHLSProxyServerObservation?
    {
        guard avPlayer === proxyPlayer else {
            return nil
        }
        let state = proxyTimeline.state
        return HybridHLSProxyServerObservation(
            seekGeneration: state.seekGeneration,
            resolvedSegmentIndices: state.resolvedSegmentIndices
        )
    }

    private let engine: AetherEngine
    private let surface: AetherPlayerView
    private let proxyTimeline: HybridHLSTimelineProxy
    private let proxyPlayer: AVPlayer
    private let proxyDuration: Double
    private let forceAVKitProxy: Bool
    private let proxyDiagnosticsID = String(
        UUID().uuidString.prefix(8)
    )
    private let eventContinuation: AsyncStream<HybridPlaybackEvent>.Continuation

    private weak var attachedController: AVPlayerViewController?
    private weak var previousControllerDelegate:
        (any AVPlayerViewControllerDelegate)?
    private var previousCustomMenuItems: [UIMenuElement] = []
    private var observations = Set<AnyCancellable>()
    private var proxyRateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var nativeMediaSelectionObserver:
        NSObjectProtocol?
    private var proxyNavigationTasks:
        [UInt64: Task<Void, Never>] = [:]
    private var completedProxyClientSeekGenerations: Set<UInt64> = []
    private struct PendingServerSeekContext {
        let oldTime: Double
        let origin: HybridProxyNavigation.Origin
    }
    private var pendingServerSeekContext: PendingServerSeekContext?
    private var requestedRate: Float = 1
    private var lastLoggedHLSMaterial: HybridHLSProxyMaterial?
    private var stopped = false
    private var audioSelectionRevision: UInt64 = 0
    private var lastNativePlayerIdentity: ObjectIdentifier?

    public init(request: HybridPlaybackRequest) async throws {
        self.request = request

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
        forceAVKitProxy = admission.requiresAetherHLSVODRemux
        let options = HybridPlaybackLoadOptions.make(
            request: request,
            externalSubtitles: externalSubtitles,
            admission: admission
        )
        do {
            try await engine.load(
                url: request.url,
                startPosition: request.initialPosition,
                options: options
            )
        } catch {
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

        let proxyDuration = try HybridProxyDurationPolicy.duration(
            admission: admission,
            engineDuration: engine.duration
        )
        self.proxyDuration = proxyDuration
        let timeline = try await ProxyMediaFactory.makeTimeline(
            duration: proxyDuration,
            initialPosition: request.initialPosition ?? 0,
            initialBufferedThrough: engine.bufferedPosition
        )
        proxyTimeline = timeline
        proxyPlayer = timeline.player
        if let nativePlayer = engine.currentAVPlayer,
           !forceAVKitProxy {
            avPlayer = nativePlayer
            engine.unbind(view: surface)
            lastNativePlayerIdentity = ObjectIdentifier(nativePlayer)
        } else {
            avPlayer = proxyPlayer
            lastNativePlayerIdentity = nil
        }
        snapshot = Self.makeSnapshot(
            engine: engine,
            route: forceAVKitProxy || engine.currentAVPlayer == nil
                ? .avKitProxy
                : .nativeAVPlayer,
            proxyState: timeline.state,
            nativeRate: requestedRate,
            audioSelectionRevision: audioSelectionRevision
        )

        super.init()
        proxyTimeline.setEventHandler { [weak self] event in
            self?.handleProxyServerEvent(event)
        }
        installObservers()
        applyAetherMaterial()
        if snapshot.route == .avKitProxy,
           let initialPosition = request.initialPosition,
           initialPosition > 0 {
            try await seek(to: initialPosition)
        }
        publishSnapshot()
    }

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
        proxyDiagnostics(
            "navigation-target-received",
            "old=\(oldTime.seconds)",
            "target=\(targetTime.seconds)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)",
            "duration=\(engine.duration)",
            "requestedRate=\(requestedRate)"
        )
        guard !stopped,
              attachedController === playerViewController,
              snapshot.route == .avKitProxy else {
            proxyDiagnostics(
                "navigation-target-ignored",
                "stopped=\(stopped)",
                "controllerMatches=\(attachedController === playerViewController)",
                "route=\(snapshot.route)"
            )
            return targetTime
        }
        guard oldTime.seconds.isFinite,
              targetTime.seconds.isFinite,
              proxyDuration.isFinite,
              proxyDuration > 0 else {
            proxyDiagnostics(
                "navigation-target-rejected",
                "reason=invalid-time-or-duration"
            )
            return targetTime
        }

        let boundedOld = max(0, min(oldTime.seconds, proxyDuration))
        let boundedTarget = max(
            0,
            min(targetTime.seconds, proxyDuration)
        )
        // AVKit asks for its final user-selected time before it performs the
        // client seek. This is the deliberate fast path: establish the same
        // authoritative Server generation and waitingToPlay state, but send
        // Aether the operation directly from the AVKit UI callback instead of
        // reflecting it back through the Server's seekRequested event.
        let generation = proxyTimeline.prepareSeek(
            to: boundedTarget,
            emitsSeekRequest: false
        )
        proxyDiagnostics(
            "avkit-seek-projected",
            "generation=\(generation)",
            "target=\(boundedTarget)",
            "serverPhase=\(proxyTimeline.state.phase)"
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
        // Completion observation only. The operation was already accepted in
        // timeToSeekAfterUserNavigatedFrom, before AVKit began its HLS seek.
        proxyDiagnostics(
            "navigation-will-resume",
            "old=\(oldTime.seconds)",
            "target=\(targetTime.seconds)",
            "serverGeneration=\(proxyTimeline.state.seekGeneration)",
            "serverPhase=\(proxyTimeline.state.phase)"
        )
        markAVKitProxyClientSeekCompleted(
            generation: proxyTimeline.state.seekGeneration
        )
    }

    public func play() {
        guard !stopped else {
            return
        }
        requestedRate = max(requestedRate, 1)
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
        guard snapshot.route == .avKitProxy else {
            engine.pause()
            publishSnapshot()
            return
        }
        commandProxyRate(0, reason: "public-pause")
        publishSnapshot()
    }

    public func seek(to seconds: Double) async throws {
        guard !stopped else {
            throw HybridPlaybackError.sessionStopped
        }
        let target = try HybridSeekTargetPolicy.target(
            requested: seconds,
            duration: engine.duration
        )
        guard snapshot.route == .avKitProxy else {
            await engine.seek(to: target)
            publishSnapshot()
            return
        }
        let oldTime = proxyTimeline.state.currentTime
        proxyDiagnostics(
            "public-seek-began",
            "target=\(target)",
            "requestedRate=\(requestedRate)",
            "enginePhase=\(engine.playbackPhase)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)"
        )
        pendingServerSeekContext = PendingServerSeekContext(
            oldTime: oldTime,
            origin: .programmatic
        )
        proxyTimeline.prepareSeek(to: target)
        requestProxyAuthoritySeek(
            to: target,
            reason: "public-seek-begin"
        )
        publishSnapshot()
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

    public func selectAudioTrack(id: Int) {
        guard !stopped,
              engine.audioTracks.contains(where: { $0.id == id }) else {
            return
        }
        engine.selectAudioTrack(index: id)
    }

    public func selectSubtitleTrack(id: Int?) {
        guard !stopped else {
            return
        }
        if let id {
            guard engine.subtitleTracks.contains(
                where: { $0.id == id }
            ) else {
                return
            }
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
        proxyNavigationTasks.values.forEach { $0.cancel() }
        proxyNavigationTasks.removeAll()
        detach()
        engine.stop()
        proxyPlayer.pause()
        proxyTimeline.stop()
        eventContinuation.finish()
    }

    deinit {
        proxyNavigationTasks.values.forEach { $0.cancel() }
        eventContinuation.finish()
        proxyRateObservation?.invalidate()
        if let nativeMediaSelectionObserver {
            NotificationCenter.default.removeObserver(
                nativeMediaSelectionObserver
            )
        }
    }

    private func installObservers() {
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
                        self.audioSelectionRevision &+= 1
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

        proxyRateObservation = proxyPlayer.observe(
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
                    "proxyTime=\(self.proxyPlayer.currentTime().seconds)",
                    "requestedRate=\(self.requestedRate)"
                )
                guard self.snapshot.route == .avKitProxy else {
                    return
                }
                if rate == 0,
                   self.proxyPlayer.timeControlStatus
                    == .waitingToPlayAtSpecifiedRate {
                    self.proxyDiagnostics(
                        "rate-forward-ignored",
                        "reason=waiting-to-play",
                        "rate=\(rate)"
                    )
                    return
                }
                self.proxyTimeline.acceptClientRate(rate)
            }
        }

        // Deliberately do not translate AVPlayerItem.timeJumpedNotification
        // into an Aether seek. Proxy initialization and programmatic seeks
        // emit that notification too. AVKit's navigation delegate above is
        // the user-intent boundary.
        installNativeMediaSelectionObserver(
            for: engine.currentAVPlayer?.currentItem
        )
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
        } else {
            lastNativePlayerIdentity = nil
            avPlayer = proxyPlayer
            newRoute = .avKitProxy
        }
        if newRoute != .avKitProxy {
            proxyNavigationTasks.values.forEach { $0.cancel() }
            proxyNavigationTasks.removeAll()
        }
        installNativeMediaSelectionObserver(
            for: player?.currentItem
        )
        if attachedController?.player !== avPlayer {
            attachedController?.player = avPlayer
        }
        do {
            try updateSurfaceAttachment(for: newRoute)
        } catch {
            eventContinuation.yield(
                .snapshot(
                    HybridPlaybackSnapshot(
                        phase: .failed(error.localizedDescription),
                        route: newRoute,
                        currentTime: engine.currentTime,
                        duration: engine.duration,
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
                            )
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
    }

    private func applyAetherMaterial() {
        guard snapshot.route == .avKitProxy else {
            return
        }
        let supplyPhase: HybridHLSProxySupplyPhase
        switch engine.playbackPhase {
        case .loading, .rebuffering, .stalled:
            // Buffer/readiness failures are valid Aether -> Server state.
            // They withhold HLS material and project waitingToPlay without
            // letting Aether replace the Server's rate, seek, or playhead.
            // A seek still has a separate Server-owned pending gate from the
            // request until the matching Aether response.
            supplyPhase = .waiting
        case .ended:
            supplyPhase = .ended
        case .error(let message):
            supplyPhase = .failed(message)
        case .idle, .playing, .paused, .seeking:
            // These Aether transport states cannot drive the authoritative
            // HLS timeline. They are consequences of Server commands.
            supplyPhase = .flowing
        }
        let material = HybridHLSProxyMaterial(
            phase: supplyPhase,
            bufferedThrough: engine.bufferedPosition
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
            "bufferedThrough=\(engine.bufferedPosition)",
            "engineTime=\(engine.currentTime)",
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
        case .stateChanged:
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
                origin: origin
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
            engine.play()
            engine.setRate(rate)
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
            await self.runProxyNavigationSeek(navigation)
        }
    }

    private func runProxyNavigationSeek(
        _ navigation: HybridProxyNavigation
    ) async {
        proxyDiagnostics(
            "navigation-seek-dispatched",
            "generation=\(navigation.generation)",
            "origin=\(navigation.origin)",
            "target=\(navigation.targetTime)"
        )
        await engine.seek(to: navigation.targetTime)
        proxyNavigationTasks[navigation.generation] = nil
        guard !Task.isCancelled,
              !stopped,
              snapshot.route == .avKitProxy else {
            proxyDiagnostics(
                "navigation-worker-stopped",
                "generation=\(navigation.generation)",
                "cancelled=\(Task.isCancelled)",
                "stopped=\(stopped)",
                "route=\(snapshot.route)"
            )
            return
        }

        proxyDiagnostics(
            "navigation-aether-returned",
            "generation=\(navigation.generation)",
            "origin=\(navigation.origin)",
            "target=\(navigation.targetTime)",
            "engineTime=\(engine.currentTime)"
        )
        let acknowledged = proxyTimeline.acknowledgeSeekResponse(
            generation: navigation.generation
        )
        let authoritativeRate = proxyTimeline.state.rate
        proxyDiagnostics(
            "navigation-server-wait-ended",
            "generation=\(navigation.generation)",
            "acknowledged=\(acknowledged)",
            "authoritativeRate=\(authoritativeRate)",
            "proxyPhase=\(proxyTimeline.state.phase)",
            "proxyTime=\(proxyTimeline.state.currentTime)"
        )
        if acknowledged {
            // Aether is a controlled timeline. Only the current Server seek
            // response may restore transport, and the Server's current rate
            // decides whether this is Play or remains Pause. A stale seek
            // response must never restart playback behind a newer seek.
            forwardRateToAether(
                authoritativeRate,
                reason: "hls-server-seek-response"
            )
        }
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
                + "session=\(proxyDiagnosticsID) "
                + "event=\(event) "
                + fields.joined(separator: " ")
        )
    }

    private func refreshMenusAndSnapshot() {
        if let controller = attachedController {
            controller.transportBarCustomMenuItems =
                previousCustomMenuItems + makeTrackMenus()
        }
        publishSnapshot()
    }

    private func installNativeMediaSelectionObserver(
        for item: AVPlayerItem?
    ) {
        if let nativeMediaSelectionObserver {
            NotificationCenter.default.removeObserver(
                nativeMediaSelectionObserver
            )
            self.nativeMediaSelectionObserver = nil
        }
        guard let item else {
            return
        }
        nativeMediaSelectionObserver =
            NotificationCenter.default.addObserver(
                forName:
                    AVPlayerItem.mediaSelectionDidChangeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.audioSelectionRevision &+= 1
                    self.refreshMenusAndSnapshot()
                }
            }
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
                    Task { @MainActor in
                        self?.selectSubtitleTrack(id: nil)
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
                        Task { @MainActor in
                            self?.selectSubtitleTrack(id: track.id)
                        }
                    }
                }
            )
            menus.append(
                UIMenu(
                    title: "Subtitles",
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
        guard !stopped else {
            return
        }
        let updated = Self.makeSnapshot(
            engine: engine,
            route: avPlayer === proxyPlayer
                ? .avKitProxy
                : .nativeAVPlayer,
            proxyState: proxyTimeline.state,
            nativeRate: requestedRate,
            audioSelectionRevision: audioSelectionRevision
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
        proxyState: HybridHLSTimelineState,
        nativeRate: Float,
        audioSelectionRevision: UInt64
    ) -> HybridPlaybackSnapshot {
        HybridPlaybackSnapshot(
            phase: route == .avKitProxy
                ? proxyState.phase
                : mapPhase(engine.playbackPhase),
            route: route,
            currentTime: route == .avKitProxy
                ? proxyState.currentTime
                : engine.currentTime,
            duration: route == .avKitProxy
                ? proxyState.duration
                : engine.duration,
            rate: route == .avKitProxy
                ? proxyState.rate
                : nativeRate,
            audioSelectionRevision: audioSelectionRevision,
            selectedAudioTrackID: engine.activeAudioTrackIndex,
            selectedSubtitleTrackID: engine.activeSubtitleTrackIndex,
            audioTracks: mapTracks(engine.audioTracks, kind: .audio),
            subtitleTracks: mapTracks(
                engine.subtitleTracks,
                kind: .subtitle
            )
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
                isCommentary: $0.isCommentary
            )
        }
    }

}
#endif
