import AVFAudio
import Foundation

public struct HybridFingerprintAudioRequest: Sendable, Equatable {
    public static let defaultDeadlineSeconds = 240.0

    public let audioSelectionRevision: UInt64
    public let sourceRange: Range<Double>
    public let deadlineSeconds: Double

    public init(
        audioSelectionRevision: UInt64,
        sourceRange: Range<Double>,
        deadlineSeconds: Double = Self.defaultDeadlineSeconds
    ) {
        self.audioSelectionRevision = audioSelectionRevision
        self.sourceRange = sourceRange
        self.deadlineSeconds = deadlineSeconds
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
        case .hlsVOD, .hlsVODPQOnlyMaster:
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
