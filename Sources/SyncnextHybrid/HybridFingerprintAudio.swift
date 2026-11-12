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

    func validate() throws {
        let duration = sourceRange.upperBound - sourceRange.lowerBound
        guard sourceRange.lowerBound.isFinite, sourceRange.upperBound.isFinite,
              sourceRange.lowerBound >= 0, duration > 0, duration <= 180 else {
            throw HybridFingerprintAudioError.invalidRange
        }
        guard deadlineSeconds.isFinite, deadlineSeconds > 0 else {
            throw HybridFingerprintAudioError.invalidDeadline
        }
    }
}

public enum HybridFingerprintAudioProvider: String, Sendable, Equatable {
    case segmentCache
    case independentRemoteHLS
    case independentDemuxer
}

public enum HybridFingerprintAudioTiming: String, Sendable, Equatable {
    case immediate
    case afterPlaybackSeek
    case whenPlaybackReachesRange
}

/// Derived from the admitted media, without changing the playback route.
public struct HybridFingerprintAudioPlan: Sendable, Equatable {
    public let provider: HybridFingerprintAudioProvider
    public let timing: HybridFingerprintAudioTiming

    func isReady(for range: Range<Double>, playbackTime: Double, isSeeking: Bool) -> Bool {
        switch timing {
        case .immediate:
            return true
        case .afterPlaybackSeek:
            return !isSeeking
        case .whenPlaybackReachesRange:
            return !isSeeking && playbackTime >= range.lowerBound
        }
    }
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

/// Shared by audio acquisition and fingerprint computation. A small tail
/// shortfall does not relax leading coverage or internal continuity checks.
enum HybridFingerprintAudioCoverage {
    static let leadingTolerance = 0.05
    /// Container duration can exceed the selected audio track because of codec
    /// padding or edit-list rounding. Use the available samples without padding.
    static let trailingTolerance = 0.25
}

public struct HybridFingerprintAudioProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case waitingForPlayback
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
    /// Use playback's cursor for finite EBML, a failed source probe, and MP4 tails.
    /// Another ranged cursor can exhaust or invalidate a cloud proxy transfer.
    static func requiresPlaybackCache(
        admission: HybridRemoteSourceAdmission,
        region: HybridFingerprintAudioRegion = .front,
        containerFormat: String? = nil
    ) -> Bool {
        switch admission {
        case .aetherDefault(.confirmedFiniteEBML), .aetherDefault(.requestFailed):
            return true
        case .aetherDefault:
            // Use the loaded demuxer's format for MP4 tails.
            return region == .back && containerFormat?.split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "mp4"
            } == true
        default:
            return false
        }
    }

    static func resolve(
        admission: HybridRemoteSourceAdmission,
        region: HybridFingerprintAudioRegion = .front,
        containerFormat: String? = nil
    ) throws -> HybridFingerprintAudioPlan {
        switch admission {
        case .hlsVOD, .hlsVODRepairedManifest, .hlsVODPQOnlyMaster:
            return HybridFingerprintAudioPlan(provider: .independentRemoteHLS, timing: .immediate)
        case .hlsVODHEVCMPEGTS:
            return HybridFingerprintAudioPlan(
                provider: region == .front ? .segmentCache : .independentRemoteHLS,
                timing: region == .front ? .afterPlaybackSeek : .immediate
            )
        case .hlsLive:
            throw HybridFingerprintAudioError.liveOrDVRUnsupported
        case .aetherDefault:
            if requiresPlaybackCache(admission: admission, region: region, containerFormat: containerFormat) {
                return HybridFingerprintAudioPlan(
                    provider: .segmentCache,
                    timing: region == .front ? .afterPlaybackSeek : .whenPlaybackReachesRange
                )
            }
            return HybridFingerprintAudioPlan(provider: .independentDemuxer, timing: .immediate)
        }
    }
}
