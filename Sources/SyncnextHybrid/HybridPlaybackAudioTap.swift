import AetherEngine

public typealias HybridPlaybackAudioBuffer = AudioTapBuffer

public enum HybridPlaybackAudioTapError: Error, Sendable {
    case sessionStopped
    case sourceUnavailable
    case sourceChanged
    case selectedAudioUnsupported
    case noDeliverySource
    case liveTimelineUnsupported
}
