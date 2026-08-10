import AVFAudio
import Foundation

public struct HybridFingerprintAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let sourceTime: Double
    public let discontinuity: Bool
}

public struct HybridFingerprintAudioBatch: @unchecked Sendable {
    public let buffers: [HybridFingerprintAudioBuffer]
    public let sourceRange: Range<Double>
    public let segmentCount: Int
    public let cacheWaitSeconds: Double
    public let decodeSeconds: Double
}

public enum HybridFingerprintAudioError: Error, Sendable, Equatable {
    case invalidRange
    case loopbackVODRequired
    case audioTrackUnavailable
    case sourceUnavailable
    case discontinuousRange
    case incompleteRange
    case sessionChanged
    case sessionStopped
}
