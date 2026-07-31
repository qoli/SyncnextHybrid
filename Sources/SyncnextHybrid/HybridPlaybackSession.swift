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

    private let engine: AetherEngine
    private let surface: AetherPlayerView
    private let proxyPlayer: AVPlayer
    private let forceAVKitProxy: Bool
    private let proxyFeedbackGate = HybridProxyFeedbackGate()
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
    private var proxyTransportIntent = HybridProxyTransportIntent()
    private var proxyNavigationTask: Task<Void, Never>?
    private var proxyClockCorrectionTask: Task<Void, Never>?
    private var proxyMirrorSeekInFlight = false
    private var suppressProxyClockCorrection = false
    private var proxyRateStabilizationDeadline: TimeInterval = 0
    private var pendingProxyMirrorSeekTarget: Double?
    private var requestedRate: Float = 1
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
        proxyPlayer = try await ProxyMediaFactory.makePlayer(
            duration: proxyDuration
        )
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
            rate: requestedRate,
            audioSelectionRevision: audioSelectionRevision
        )

        super.init()
        installObservers()
        synchronizeProxyFromEngine(
            forceSeek: true,
            reason: "session-init"
        )
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
        willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) {
        proxyDiagnostics(
            "navigation-received",
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
                "navigation-ignored",
                "stopped=\(stopped)",
                "controllerMatches=\(attachedController === playerViewController)",
                "route=\(snapshot.route)"
            )
            return
        }
        guard let navigation =
                proxyTransportIntent.beginUserNavigation(
                    from: oldTime.seconds,
                    to: targetTime.seconds,
                    duration: engine.duration,
                    resumeRate: requestedRate
                ) else {
            proxyDiagnostics(
                "navigation-rejected",
                "reason=invalid-time-or-duration"
            )
            return
        }

        proxyDiagnostics(
            "navigation-began",
            "generation=\(navigation.generation)",
            "target=\(navigation.targetTime)",
            "distance=\(navigation.distance)"
        )

        armProxyRateStabilization(for: requestedRate)

        proxyNavigationTask?.cancel()
        pendingProxyMirrorSeekTarget = nil
        engine.pause()
        mirrorProxyRate(0, reason: "navigation-begin")
        publishSnapshot()

        proxyNavigationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.engine.seek(to: navigation.targetTime)
            guard !Task.isCancelled,
                  !self.stopped,
                  self.snapshot.route == .avKitProxy,
                  let desiredRate =
                    self.proxyTransportIntent
                    .completeUserNavigation(navigation) else {
                self.proxyDiagnostics(
                    "navigation-completion-ignored",
                    "generation=\(navigation.generation)",
                    "cancelled=\(Task.isCancelled)",
                    "stopped=\(self.stopped)",
                    "route=\(self.snapshot.route)"
                )
                return
            }
            self.proxyNavigationTask = nil
            self.proxyDiagnostics(
                "navigation-completed",
                "generation=\(navigation.generation)",
                "target=\(navigation.targetTime)",
                "engineTime=\(self.engine.currentTime)",
                "desiredRate=\(desiredRate)"
            )
            self.applyProxyRateIntent(
                desiredRate,
                reason: "navigation-complete"
            )
            self.synchronizeProxyFromEngine(
                forceSeek: false,
                reason: "navigation-complete"
            )
            self.publishSnapshot()
        }
    }

    public func play() {
        guard !stopped else {
            return
        }
        requestedRate = max(requestedRate, 1)
        guard proxyTransportIntent.recordDesiredRate(requestedRate) else {
            mirrorProxyRate(0, reason: "public-play-navigation-pending")
            publishSnapshot()
            return
        }
        engine.play()
        engine.setRate(requestedRate)
        mirrorProxyRate(requestedRate, reason: "public-play")
        publishSnapshot()
    }

    public func pause() {
        guard !stopped else {
            return
        }
        guard proxyTransportIntent.recordDesiredRate(0) else {
            engine.pause()
            mirrorProxyRate(0, reason: "public-pause-navigation-pending")
            publishSnapshot()
            return
        }
        engine.pause()
        mirrorProxyRate(0, reason: "public-pause")
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
        await engine.seek(to: target)
        mirrorProxySeek(to: target, reason: "public-seek")
        publishSnapshot()
    }

    public func setRate(_ rate: Float) {
        guard !stopped else {
            return
        }
        let bounded = max(0, min(rate, engine.maxSupportedRate))
        requestedRate = bounded
        armProxyRateStabilization(for: bounded)
        guard proxyTransportIntent.recordDesiredRate(bounded) else {
            engine.pause()
            mirrorProxyRate(0, reason: "public-set-rate-navigation-pending")
            publishSnapshot()
            return
        }
        if bounded == 0 {
            engine.pause()
        } else {
            engine.setRate(bounded)
        }
        mirrorProxyRate(bounded, reason: "public-set-rate")
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
        proxyNavigationTask?.cancel()
        proxyNavigationTask = nil
        proxyClockCorrectionTask?.cancel()
        proxyClockCorrectionTask = nil
        proxyTransportIntent.cancelUserNavigation()
        pendingProxyMirrorSeekTarget = nil
        detach()
        engine.stop()
        proxyPlayer.pause()
        eventContinuation.finish()
    }

    deinit {
        proxyNavigationTask?.cancel()
        proxyClockCorrectionTask?.cancel()
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
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.$duration
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.publishSnapshot()
                }
            }
            .store(in: &observations)

        engine.clock.$currentTime
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.synchronizeProxyFromEngine(
                        forceSeek: false,
                        reason: "engine-clock"
                    )
                    self.publishSnapshot()
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

        let feedbackGate = proxyFeedbackGate
        proxyRateObservation = proxyPlayer.observe(
            \.rate,
            options: [.new]
        ) { [weak self] _, change in
            guard let rate = change.newValue else {
                return
            }
            let decision =
                feedbackGate.rateObservationDecision(rate)
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.proxyDiagnostics(
                    "rate-observed",
                    "rate=\(rate)",
                    "decision=\(decision.disposition.rawValue)",
                    "matchedAge=\(decision.matchedMirroredRateAge.map(String.init(describing:)) ?? "none")",
                    "pendingRates=\(decision.pendingMirroredRateCount)",
                    "activeSeeks=\(decision.activeMirroredSeekCount)",
                    "enginePhase=\(self.engine.playbackPhase)",
                    "engineTime=\(self.engine.currentTime)",
                    "proxyTime=\(self.proxyPlayer.currentTime().seconds)",
                    "requestedRate=\(self.requestedRate)"
                )
                guard decision.shouldForward,
                      self.snapshot.route == .avKitProxy else {
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
                if rate == 0,
                   self.requestedRate > 1,
                   ProcessInfo.processInfo.systemUptime
                    < self.proxyRateStabilizationDeadline {
                    self.mirrorProxyRate(
                        self.requestedRate,
                        reason: "fast-rate-stabilization"
                    )
                    return
                }
                let canApplyImmediately =
                    self.proxyTransportIntent
                    .recordDesiredRate(rate)
                guard canApplyImmediately else {
                    self.proxyDiagnostics(
                        "rate-forward-deferred",
                        "rate=\(rate)",
                        "reason=navigation-active"
                    )
                    if rate != 0 {
                        self.mirrorProxyRate(
                            0,
                            reason: "rate-observed-navigation-active"
                        )
                    }
                    self.publishSnapshot()
                    return
                }
                if rate == 0 {
                    self.deferProxyClockCorrection()
                }
                self.applyProxyRateIntent(
                    rate,
                    reason: "rate-observed-forwarded"
                )
                self.publishSnapshot()
            }
        }

        // Deliberately do not translate AVPlayerItem.timeJumpedNotification
        // into an Aether seek. The proxy's own mirrored seeks and clock
        // corrections emit that notification too. AVKit's navigation
        // delegate above is the user-intent boundary.
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
            proxyNavigationTask?.cancel()
            proxyNavigationTask = nil
            proxyTransportIntent.cancelUserNavigation()
            pendingProxyMirrorSeekTarget = nil
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

    private func synchronizeProxyFromEngine(
        forceSeek: Bool,
        reason: String
    ) {
        guard !stopped,
              !proxyTransportIntent.isNavigating else {
            return
        }
        let sourceTime = engine.currentTime
        let proxyTime = proxyPlayer.currentTime().seconds
        let canCorrectClockDrift: Bool
        switch engine.playbackPhase {
        case .playing:
            // Both clocks already advance at requestedRate. Periodic exact
            // seeks here can still be in flight when AVKit begins a user
            // navigation, causing AVPlayer to cancel that navigation seek.
            canCorrectClockDrift = false
        case .paused, .idle, .loading, .seeking, .rebuffering,
             .stalled, .ended, .error:
            canCorrectClockDrift = true
        }
        if sourceTime.isFinite,
           (
            forceSeek
                || !proxyTime.isFinite
                || (
                    !suppressProxyClockCorrection
                        && canCorrectClockDrift
                        && abs(sourceTime - proxyTime) > 0.75
                )
           ) {
            mirrorProxySeek(
                to: sourceTime,
                reason: "\(reason)-clock-correction"
            )
        }

        switch engine.playbackPhase {
        case .playing:
            mirrorProxyRate(
                max(requestedRate, 1),
                reason: "\(reason)-engine-playing"
            )
        case .paused, .idle, .loading, .seeking, .rebuffering,
             .stalled, .ended, .error:
            mirrorProxyRate(
                0,
                reason: "\(reason)-engine-not-playing"
            )
        }
    }

    private func deferProxyClockCorrection() {
        suppressProxyClockCorrection = true
        proxyClockCorrectionTask?.cancel()
        proxyClockCorrectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, !self.stopped else {
                return
            }
            self.proxyClockCorrectionTask = nil
            self.suppressProxyClockCorrection = false
            self.synchronizeProxyFromEngine(
                forceSeek: false,
                reason: "deferred-clock-correction"
            )
        }
    }

    private func armProxyRateStabilization(for rate: Float) {
        guard rate > 1 else {
            return
        }
        // AVPlayer may publish an automatic zero while applying a newly
        // selected fast-play rate. Treat only that short transition as
        // mirrored feedback; a later user pause remains authoritative.
        proxyRateStabilizationDeadline =
            ProcessInfo.processInfo.systemUptime + 3
    }

    private func mirrorProxySeek(
        to seconds: Double,
        reason: String
    ) {
        let target = max(0, min(seconds, engine.duration))
        pendingProxyMirrorSeekTarget = target
        proxyDiagnostics(
            "seek-queued",
            "reason=\(reason)",
            "requested=\(seconds)",
            "target=\(target)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)",
            "inFlight=\(proxyMirrorSeekInFlight)",
            "navigating=\(proxyTransportIntent.isNavigating)"
        )
        guard !proxyMirrorSeekInFlight,
              !proxyTransportIntent.isNavigating else {
            return
        }
        performPendingProxyMirrorSeek()
    }

    private func performPendingProxyMirrorSeek() {
        guard let target = pendingProxyMirrorSeekTarget,
              !proxyMirrorSeekInFlight,
              !proxyTransportIntent.isNavigating else {
            return
        }
        pendingProxyMirrorSeekTarget = nil
        proxyMirrorSeekInFlight = true
        let feedbackGate = proxyFeedbackGate
        let seekToken = feedbackGate.beginMirroredSeek()
        proxyDiagnostics(
            "seek-dispatched",
            "token=\(seekToken)",
            "target=\(target)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)"
        )
        proxyPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            feedbackGate.completeMirroredSeek(seekToken)
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.proxyMirrorSeekInFlight = false
                self.proxyDiagnostics(
                    "seek-completed",
                    "token=\(seekToken)",
                    "finished=\(finished)",
                    "target=\(target)",
                    "engineTime=\(self.engine.currentTime)",
                    "proxyTime=\(self.proxyPlayer.currentTime().seconds)"
                )
                guard !self.stopped else {
                    self.pendingProxyMirrorSeekTarget = nil
                    return
                }
                guard !self.proxyTransportIntent.isNavigating else {
                    self.pendingProxyMirrorSeekTarget = nil
                    return
                }
                if self.pendingProxyMirrorSeekTarget != nil {
                    self.performPendingProxyMirrorSeek()
                } else {
                    self.synchronizeProxyFromEngine(
                        forceSeek: false,
                        reason: "mirror-seek-complete"
                    )
                }
            }
        }
    }

    private func applyProxyRateIntent(
        _ rate: Float,
        reason: String
    ) {
        proxyDiagnostics(
            "rate-intent-applied",
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
        mirrorProxyRate(rate, reason: reason)
    }

    private func mirrorProxyRate(
        _ rate: Float,
        reason: String
    ) {
        guard proxyPlayer.rate != rate else {
            return
        }
        let previousRate = proxyPlayer.rate
        let pendingCount =
            proxyFeedbackGate.performMirroredRateChange(to: rate) {
            if rate == 0 {
                proxyPlayer.pause()
            } else {
                proxyPlayer.defaultRate = rate
                proxyPlayer.play()
            }
        }
        proxyDiagnostics(
            "rate-mirrored",
            "reason=\(reason)",
            "from=\(previousRate)",
            "to=\(rate)",
            "pendingRates=\(pendingCount)",
            "enginePhase=\(engine.playbackPhase)",
            "engineTime=\(engine.currentTime)",
            "proxyTime=\(proxyPlayer.currentTime().seconds)",
            "navigating=\(proxyTransportIntent.isNavigating)"
        )
    }

    private func proxyDiagnostics(
        _ event: String,
        _ fields: String...
    ) {
        print(
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
            rate: requestedRate,
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
        rate: Float,
        audioSelectionRevision: UInt64
    ) -> HybridPlaybackSnapshot {
        HybridPlaybackSnapshot(
            phase: mapPhase(engine.playbackPhase),
            route: route,
            currentTime: engine.currentTime,
            duration: engine.duration,
            rate: rate,
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
