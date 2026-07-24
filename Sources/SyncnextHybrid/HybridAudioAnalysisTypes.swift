import AVFAudio
import Foundation

public enum HybridAudioAnalysisError: Error, Sendable, Equatable, LocalizedError {
    case invalidRange
    case rangeOutsideSource
    case noActivePlayback
    case liveOrDVRUnsupported
    case sourceNotSeekable
    case selectedAudioTrackUnavailable
    case sourceTrackChanged
    case independentReaderUnavailable
    case streamAlreadyActive
    case concurrentConsumer
    case cancelled
    case demuxFailed(String)
    case decoderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            "Audio-analysis range must be finite, non-negative, and non-empty"
        case .rangeOutsideSource:
            "Audio-analysis range is outside the admitted VOD timeline"
        case .noActivePlayback:
            "No active playback session is available for audio analysis"
        case .liveOrDVRUnsupported:
            "Live and DVR audio analysis are not supported in SyncnextHybrid V1"
        case .sourceNotSeekable:
            "The source cannot provide an independent seekable cursor"
        case .selectedAudioTrackUnavailable:
            "The selected AetherEngine audio track is unavailable"
        case .sourceTrackChanged:
            "The selected FFmpeg audio-track contract changed"
        case .independentReaderUnavailable:
            "The source cannot create an independent reader"
        case .streamAlreadyActive:
            "This playback session already has an active audio-analysis stream"
        case .concurrentConsumer:
            "HybridAudioAnalysisStream supports exactly one consumer"
        case .cancelled:
            "Audio analysis was cancelled"
        case .demuxFailed(let message):
            "Audio-analysis demux failed: \(message)"
        case .decoderFailed(let message):
            "Audio-analysis decode failed: \(message)"
        }
    }
}

public struct HybridAudioAnalysisBuffer: @unchecked Sendable {
    /// Always mono Float32, 48 kHz, and non-interleaved.
    public let pcm: AVAudioPCMBuffer
    /// Exact position on the fixed 48 kHz source sample axis.
    public let sourceSamplePosition: Int64
    public let isDiscontinuous: Bool

    public var sourceTime: Double {
        Double(sourceSamplePosition) / 48_000
    }

    init(
        pcm: AVAudioPCMBuffer,
        sourceSamplePosition: Int64,
        isDiscontinuous: Bool
    ) {
        self.pcm = pcm
        self.sourceSamplePosition = sourceSamplePosition
        self.isDiscontinuous = isDiscontinuous
    }
}

public enum HybridAudioAnalysisFormat {
    public static let sampleRate: Double = 48_000

    public static var pcm: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }
}
