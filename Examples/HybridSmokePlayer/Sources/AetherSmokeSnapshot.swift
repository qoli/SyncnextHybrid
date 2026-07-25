import AetherEngine
import AVFoundation
import Foundation

struct AetherSmokeSnapshot {
    let phase: PlaybackPhase
    let currentTime: Double
    let duration: Double
    let requestedRate: Float
    let backend: PlaybackBackend
    let hasCurrentAVPlayer: Bool
    let videoWidth: Int32
    let videoHeight: Int32
    let audioTrackCount: Int
    let subtitleTrackCount: Int

    @MainActor
    init(
        engine: AetherEngine,
        requestedRate: Float
    ) {
        let sourceWidth = engine.sourceVideoWidth
        let sourceHeight = engine.sourceVideoHeight
        let presentationSize =
            engine.currentAVPlayer?.currentItem?.presentationSize
            ?? .zero
        let dimensions = AetherSmokeState.videoDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            nativePresentationWidth:
                Double(presentationSize.width),
            nativePresentationHeight:
                Double(presentationSize.height)
        )

        phase = engine.playbackPhase
        currentTime = engine.clock.currentTime
        duration = engine.duration
        self.requestedRate = requestedRate
        backend = engine.playbackBackend
        hasCurrentAVPlayer = engine.currentAVPlayer != nil
        videoWidth = dimensions.width
        videoHeight = dimensions.height
        audioTrackCount = engine.audioTracks.count
        subtitleTrackCount = engine.subtitleTracks.count
    }

    init(
        phase: PlaybackPhase,
        currentTime: Double,
        duration: Double,
        requestedRate: Float,
        backend: PlaybackBackend,
        hasCurrentAVPlayer: Bool,
        videoWidth: Int32,
        videoHeight: Int32,
        audioTrackCount: Int,
        subtitleTrackCount: Int
    ) {
        self.phase = phase
        self.currentTime = currentTime
        self.duration = duration
        self.requestedRate = requestedRate
        self.backend = backend
        self.hasCurrentAVPlayer = hasCurrentAVPlayer
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.audioTrackCount = audioTrackCount
        self.subtitleTrackCount = subtitleTrackCount
    }
}

enum AetherSmokeState {
    static func videoDimensions(
        sourceWidth: Int32,
        sourceHeight: Int32,
        nativePresentationWidth: Double,
        nativePresentationHeight: Double
    ) -> (width: Int32, height: Int32) {
        if sourceWidth > 0, sourceHeight > 0 {
            return (sourceWidth, sourceHeight)
        }
        guard nativePresentationWidth.isFinite,
              nativePresentationHeight.isFinite,
              nativePresentationWidth > 0,
              nativePresentationHeight > 0,
              nativePresentationWidth <= Double(Int32.max),
              nativePresentationHeight <= Double(Int32.max) else {
            return (sourceWidth, sourceHeight)
        }
        return (
            Int32(nativePresentationWidth.rounded()),
            Int32(nativePresentationHeight.rounded())
        )
    }

    static func validateVideo(
        width: Int32,
        height: Int32,
        backend: PlaybackBackend
    ) throws {
        guard width > 0, height > 0 else {
            throw SmokeFailure.aetherVideoRequired(
                width: width,
                height: height
            )
        }
        switch backend {
        case .native, .software:
            return
        case .none, .aether:
            throw SmokeFailure.aetherBackendUnavailable(
                backend.rawValue
            )
        case .audio:
            throw SmokeFailure.aetherVideoRequired(
                width: width,
                height: height
            )
        }
    }
}

extension PlaybackPhase {
    var smokeName: String {
        switch self {
        case .idle:
            "idle"
        case .loading:
            "loading"
        case .playing:
            "playing"
        case .paused:
            "paused"
        case .seeking:
            "seeking"
        case .rebuffering:
            "rebuffering"
        case .stalled:
            "stalled"
        case .ended:
            "ended"
        case .error:
            "failed"
        }
    }
}
