import AVFAudio
import Foundation

public struct HybridFingerprintAudioRequest: Sendable, Equatable {
    public let audioSelectionRevision: UInt64
    public let sourceRange: Range<Double>

    public init(
        audioSelectionRevision: UInt64,
        sourceRange: Range<Double>
    ) {
        self.audioSelectionRevision = audioSelectionRevision
        self.sourceRange = sourceRange
    }
}

public enum HybridFingerprintAudioProvider: String, Sendable, Equatable {
    case segmentCache
    case independentRemoteHLS
    case independentDemuxer
}

public struct HybridFingerprintAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let sourceTime: Double
    public let discontinuity: Bool
}

public struct HybridFingerprintAudioBatch: @unchecked Sendable {
    public let buffers: [HybridFingerprintAudioBuffer]
    public let sourceRange: Range<Double>
    public let provider: HybridFingerprintAudioProvider
    public let segmentCount: Int
    public let preparationSeconds: Double
    public let cacheWaitSeconds: Double
    public let decodeSeconds: Double
}

public enum HybridFingerprintAudioError: Error, Sendable, Equatable {
    case invalidRange
    case liveOrDVRUnsupported
    case audioTrackUnavailable
    case audioSelectionChanged
    case sourceUnavailable
    case discontinuousRange
    case incompleteRange
    case sessionChanged
    case sessionStopped
}

enum HybridFingerprintAudioProviderResolver {
    static func resolve(
        admission: HybridRemoteSourceAdmission
    ) throws -> HybridFingerprintAudioProvider {
        switch admission {
        case .hlsVOD:
            return .independentRemoteHLS
        case .hlsVODHEVCMPEGTS:
            return .segmentCache
        case .hlsLive:
            throw HybridFingerprintAudioError.liveOrDVRUnsupported
        case .aetherDefault:
            return .independentDemuxer
        }
    }
}
