import AVFAudio
import Foundation

public enum HybridFingerprintAudioRegion: Sendable, Equatable {
    case front
    case back
}

public struct HybridFingerprintAudioRequest: Sendable, Equatable {
    public static let defaultDeadlineSeconds = 240.0

    public let sourceRange: Range<Double>
    public let deadlineSeconds: Double
    public let region: HybridFingerprintAudioRegion

    public init(
        sourceRange: Range<Double>,
        deadlineSeconds: Double = Self.defaultDeadlineSeconds,
        region: HybridFingerprintAudioRegion = .front
    ) {
        self.sourceRange = sourceRange
        self.deadlineSeconds = deadlineSeconds
        self.region = region
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

public struct HybridFingerprintAudioProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case preparing
        case decoding
    }

    public let provider: HybridFingerprintAudioProvider
    public let phase: Phase
    public let sourceTime: Double
    public let sourceRange: Range<Double>
    public let fraction: Double
    public let elapsedSeconds: Double
}

public typealias HybridFingerprintAudioProgressHandler =
    @MainActor @Sendable (HybridFingerprintAudioProgress) async -> Void

public enum HybridFingerprintAudioError: Error, Sendable, Equatable {
    case invalidRange
    case invalidDeadline
    case deadlineExceeded
    case liveOrDVRUnsupported
    case audioTrackUnavailable
    case sourceUnavailable
    case discontinuousRange
    case incompleteRange
    case sessionChanged
    case sessionStopped

    /// Only material acquisition failures may use the caller-authorized extractor.
    public var canUseIntroAudioExtraction: Bool {
        switch self {
        case .sourceUnavailable, .discontinuousRange, .incompleteRange:
            return true
        default:
            return false
        }
    }
}

enum HybridFingerprintAudioProviderResolver {
    static func resolve(
        admission: HybridRemoteSourceAdmission,
        region: HybridFingerprintAudioRegion = .front
    ) throws -> HybridFingerprintAudioProvider {
        switch admission {
        case .hlsVOD, .hlsVODRepairedManifest, .hlsVODPQOnlyMaster:
            return .independentRemoteHLS
        case .hlsVODHEVCMPEGTS:
            return region == .front ? .segmentCache : .independentRemoteHLS
        case .hlsLive:
            throw HybridFingerprintAudioError.liveOrDVRUnsupported
        case .aetherDefault:
            return .independentDemuxer
        }
    }
}
