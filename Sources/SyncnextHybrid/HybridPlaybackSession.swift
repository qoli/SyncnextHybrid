#if os(tvOS)
import AetherEngine
import AVFoundation
import AVKit
import Combine
import Foundation
import UIKit

private final class WeakHybridPlaybackSessionBox: @unchecked Sendable {
    weak var value: HybridPlaybackSession?

    init(_ value: HybridPlaybackSession) {
        self.value = value
    }
}

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
    private let proxyFeedbackGate = HybridProxyFeedbackGate()
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
    private var proxyMirrorSeekInFlight = false
    private var pendingProxyMirrorSeekTarget: Double?
    private var requestedRate: Float = 1
    private var stopped = false
    private var activeAnalysisRun: HybridAudioAnalysisRun?
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

        proxyPlayer = try await ProxyMediaFactory.makePlayer(
            duration: engine.duration
        )
        if let nativePlayer = engine.currentAVPlayer {
            avPlayer = nativePlayer
            engine.unbind(view: surface)
            lastNativePlayerIdentity = ObjectIdentifier(nativePlayer)
        } else {
            avPlayer = proxyPlayer
            lastNativePlayerIdentity = nil
        }
        snapshot = Self.makeSnapshot(
            engine: engine,
            route: engine.currentAVPlayer == nil
                ? .avKitProxy
                : .nativeAVPlayer,
            rate: requestedRate,
            audioSelectionRevision: audioSelectionRevision
        )

        super.init()
        installObservers()
        synchronizeProxyFromEngine(forceSeek: true)
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
        guard !stopped,
              attachedController === playerViewController,
              snapshot.route == .avKitProxy,
              let navigation =
                proxyTransportIntent.beginUserNavigation(
                    from: oldTime.seconds,
                    to: targetTime.seconds,
                    duration: engine.duration,
                    resumeRate: requestedRate
                ) else {
            return
        }

        proxyNavigationTask?.cancel()
        pendingProxyMirrorSeekTarget = nil
        engine.pause()
        mirrorProxyRate(0)
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
                return
            }
            self.proxyNavigationTask = nil
            self.applyProxyRateIntent(desiredRate)
            self.synchronizeProxyFromEngine(forceSeek: false)
            self.publishSnapshot()
        }
    }

    public func play() {
        guard !stopped else {
            return
        }
        requestedRate = max(requestedRate, 1)
        guard proxyTransportIntent.recordDesiredRate(requestedRate) else {
            mirrorProxyRate(0)
            publishSnapshot()
            return
        }
        engine.play()
        engine.setRate(requestedRate)
        mirrorProxyRate(requestedRate)
        publishSnapshot()
    }

    public func pause() {
        guard !stopped else {
            return
        }
        guard proxyTransportIntent.recordDesiredRate(0) else {
            engine.pause()
            mirrorProxyRate(0)
            publishSnapshot()
            return
        }
        engine.pause()
        mirrorProxyRate(0)
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
        mirrorProxySeek(to: target)
        publishSnapshot()
    }

    public func setRate(_ rate: Float) {
        guard !stopped else {
            return
        }
        let bounded = max(0, min(rate, engine.maxSupportedRate))
        requestedRate = bounded
        guard proxyTransportIntent.recordDesiredRate(bounded) else {
            engine.pause()
            mirrorProxyRate(0)
            publishSnapshot()
            return
        }
        if bounded == 0 {
            engine.pause()
        } else {
            engine.setRate(bounded)
        }
        mirrorProxyRate(bounded)
        publishSnapshot()
    }

    public func selectAudioTrack(id: Int) {
        guard !stopped,
              engine.audioTracks.contains(where: { $0.id == id }) else {
            return
        }
        cancelAudioAnalysis()
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

    public func audioAnalysisStream(
        request: HybridAudioAnalysisRequest
    ) throws -> HybridAudioAnalysisStream {
        guard !stopped else {
            throw HybridAudioAnalysisError.noActivePlayback
        }
        guard activeAnalysisRun == nil else {
            throw HybridAudioAnalysisError.streamAlreadyActive
        }
        try HybridAudioAnalysisSelectionGate.validate(
            request: request,
            sessionRevision: audioSelectionRevision,
            snapshot: snapshot
        )
        let range = request.sourceRange
        guard range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.lowerBound >= 0,
              range.upperBound > range.lowerBound else {
            throw HybridAudioAnalysisError.invalidRange
        }

        let source: AetherIndependentAudioSource
        do {
            source = try engine.independentAudioSource()
        } catch {
            throw Self.mapAnalysisSourceError(error)
        }
        guard range.upperBound <= source.durationSeconds + 0.001 else {
            throw HybridAudioAnalysisError.rangeOutsideSource
        }

        let context = HybridAudioAnalysisRun()
        activeAnalysisRun = context
        let stream = HybridAudioAnalysisStream(
            gate: context.gate,
            cancel: { context.cancel() }
        )
        let runID = context.id
        let sessionBox = WeakHybridPlaybackSessionBox(self)
        let task = Task.detached(priority: .utility) {
            await HybridAudioAnalysisRunner.run(
                context: context,
                source: source,
                range: range
            ) { error in
                Task { @MainActor in
                    guard let self = sessionBox.value,
                          self.activeAnalysisRun?.id == runID else {
                        return
                    }
                    self.activeAnalysisRun = nil
                    if let error, error != .cancelled {
                        self.eventContinuation.yield(
                            .audioAnalysisUnavailable(error)
                        )
                    }
                }
            }
        }
        context.install(task: task)
        return stream
    }

    public func cancelAudioAnalysis() {
        activeAnalysisRun?.cancel()
        activeAnalysisRun = nil
    }

    public func stop() {
        guard !stopped else {
            return
        }
        stopped = true
        proxyNavigationTask?.cancel()
        proxyNavigationTask = nil
        proxyTransportIntent.cancelUserNavigation()
        pendingProxyMirrorSeekTarget = nil
        cancelAudioAnalysis()
        detach()
        engine.stop()
        proxyPlayer.pause()
        eventContinuation.finish()
    }

    deinit {
        activeAnalysisRun?.cancel()
        proxyNavigationTask?.cancel()
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
                    self.synchronizeProxyFromEngine(forceSeek: false)
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
                        self.cancelAudioAnalysis()
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
            let shouldForward =
                feedbackGate.shouldForwardRateObservation(rate)
            guard shouldForward else {
                return
            }
            Task { @MainActor in
                guard let self,
                      self.snapshot.route == .avKitProxy else {
                    return
                }
                let canApplyImmediately =
                    self.proxyTransportIntent
                    .recordDesiredRate(rate)
                guard canApplyImmediately else {
                    if rate != 0 {
                        self.mirrorProxyRate(0)
                    }
                    self.publishSnapshot()
                    return
                }
                self.applyProxyRateIntent(rate)
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
        if let player {
            let newIdentity = ObjectIdentifier(player)
            if let priorIdentity = lastNativePlayerIdentity,
               priorIdentity != newIdentity {
                cancelAudioAnalysis()
            }
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
        attachedController?.player = avPlayer
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

    private func synchronizeProxyFromEngine(forceSeek: Bool) {
        guard !stopped,
              !proxyTransportIntent.isNavigating else {
            return
        }
        let sourceTime = engine.currentTime
        let proxyTime = proxyPlayer.currentTime().seconds
        if sourceTime.isFinite,
           (
            forceSeek
                || !proxyTime.isFinite
                || abs(sourceTime - proxyTime) > 0.75
           ) {
            mirrorProxySeek(to: sourceTime)
        }

        switch engine.playbackPhase {
        case .playing:
            mirrorProxyRate(max(requestedRate, 1))
        case .paused, .idle, .loading, .seeking, .rebuffering,
             .stalled, .ended, .error:
            mirrorProxyRate(0)
        }
    }

    private func mirrorProxySeek(to seconds: Double) {
        let target = max(0, min(seconds, engine.duration))
        pendingProxyMirrorSeekTarget = target
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
        proxyPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            feedbackGate.completeMirroredSeek(seekToken)
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.proxyMirrorSeekInFlight = false
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
                    self.synchronizeProxyFromEngine(forceSeek: false)
                }
            }
        }
    }

    private func applyProxyRateIntent(_ rate: Float) {
        if rate == 0 {
            engine.pause()
        } else {
            requestedRate = rate
            engine.play()
            engine.setRate(rate)
        }
        mirrorProxyRate(rate)
    }

    private func mirrorProxyRate(_ rate: Float) {
        guard proxyPlayer.rate != rate else {
            return
        }
        proxyFeedbackGate.performMirroredRateChange(to: rate) {
            if rate == 0 {
                proxyPlayer.pause()
            } else {
                proxyPlayer.rate = rate
            }
        }
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
                    self.cancelAudioAnalysis()
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

    private static func mapAnalysisSourceError(
        _ error: Error
    ) -> HybridAudioAnalysisError {
        guard let sourceError =
            error as? AetherIndependentAudioSourceError else {
            return .demuxFailed(String(describing: error))
        }
        return switch sourceError {
        case .noActiveSession:
            .noActivePlayback
        case .liveOrDVRUnsupported:
            .liveOrDVRUnsupported
        case .sourceNotSeekable:
            .sourceNotSeekable
        case .selectedAudioTrackUnavailable:
            .selectedAudioTrackUnavailable
        case .independentReaderUnavailable:
            .independentReaderUnavailable
        case .remoteHLSPreparationRequired:
            .demuxFailed(
                "remote HLS VOD requires bounded preparation"
            )
        }
    }
}
#endif
