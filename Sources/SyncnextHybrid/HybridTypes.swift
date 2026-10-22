import AVFoundation
import Foundation

public struct HybridExternalSubtitle: Sendable, Equatable {
    public let url: URL
    public let name: String?
    public let language: String?
    public let httpHeaders: [String: String]?
    public let formatHint: String?

    public init(
        url: URL,
        name: String? = nil,
        language: String? = nil,
        httpHeaders: [String: String]? = nil,
        formatHint: String? = nil
    ) {
        self.url = url
        self.name = name
        self.language = language
        self.httpHeaders = httpHeaders
        self.formatHint = formatHint
    }
}

public struct HybridPlaybackRequest: Sendable, Equatable {
    public let url: URL
    public let httpHeaders: [String: String]
    /// Selects Aether's persistent HTTP/1.1 policy for this source.
    public let heldSourceConnection: Bool
    public let initialPosition: Double?
    public let externalSubtitles: [HybridExternalSubtitle]
    public let preferredAudioLanguages: [String]
    public let preferredSubtitleLanguages: [String]

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        heldSourceConnection: Bool = false,
        initialPosition: Double? = nil,
        externalSubtitles: [HybridExternalSubtitle] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = []
    ) throws {
        if let initialPosition,
           (!initialPosition.isFinite || initialPosition < 0) {
            throw HybridPlaybackError.invalidInitialPosition
        }
        self.url = url
        self.httpHeaders = httpHeaders
        self.heldSourceConnection = heldSourceConnection
        self.initialPosition = initialPosition
        self.externalSubtitles = externalSubtitles
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
    }
}

public enum HybridSubtitleSelectionOrigin: Sendable {
    case programmatic
    case user
}

public struct HybridMediaTrack: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case audio
        case subtitle
    }

    public let id: Int
    public let kind: Kind
    public let name: String
    public let language: String?
    public let codec: String
    public let channelCount: Int
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let isCommentary: Bool
    public let isExternal: Bool

    public init(
        id: Int,
        kind: Kind,
        name: String,
        language: String?,
        codec: String,
        channelCount: Int,
        isDefault: Bool,
        isForced: Bool,
        isHearingImpaired: Bool,
        isCommentary: Bool,
        isExternal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.language = language
        self.codec = codec
        self.channelCount = channelCount
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isCommentary = isCommentary
        self.isExternal = isExternal
    }
}

public enum HybridPlaybackRoute: Sendable, Equatable {
    /// AVKit owns the same native AVPlayer instance published by AetherEngine.
    case nativeAVPlayer
    /// AVKit owns the silent black HLS timeline while AetherEngine renders and
    /// supplies buffer availability.
    case avKitProxy
}

/// App lifecycle edges that affect an already-mounted playback session.
/// The caller reports UIKit lifecycle only; the Hybrid session owns the
/// recovery policy and AetherEngine rebuild.
public enum HybridPlaybackLifecycleEvent: Sendable, Equatable {
    case enteredBackground
    case becameActive
}

public enum HybridPlaybackPhase: Sendable, Equatable {
    case idle
    case loading
    case waitingToPlay
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled
    case ended
    case failed(String)
}

/// Measurements of the actual media, independent of the AVKit proxy item.
public struct HybridPlaybackDiagnostics: Sendable, Equatable {
    public let videoSize: CGSize?
    public let averageBitrateMbps: Double?
    /// Container-declared video rate; separate from the measured playback mean.
    public let declaredVideoBitrateMbps: Double?
    public let bufferSeconds: Double?

    /// The panel prefers the playback mean, then the container declaration.
    public var bitrateMbps: Double? {
        averageBitrateMbps ?? declaredVideoBitrateMbps
    }

    public init(
        videoSize: CGSize? = nil,
        averageBitrateMbps: Double? = nil,
        declaredVideoBitrateMbps: Double? = nil,
        bufferSeconds: Double? = nil
    ) {
        self.videoSize = videoSize.flatMap {
            $0.width.isFinite && $0.height.isFinite
                && $0.width > 0 && $0.height > 0 ? $0 : nil
        }
        self.averageBitrateMbps = averageBitrateMbps.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.declaredVideoBitrateMbps = declaredVideoBitrateMbps.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.bufferSeconds = bufferSeconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
    }

    init(
        sourceVideoWidth: Int32,
        sourceVideoHeight: Int32,
        averageBitrateMbps: Double?,
        sourceVideoBitrate: Int64 = 0,
        bufferedPosition: Double,
        sourceTime: Double
    ) {
        self.init(
            videoSize: CGSize(
                width: Int(sourceVideoWidth),
                height: Int(sourceVideoHeight)
            ),
            averageBitrateMbps: averageBitrateMbps,
            declaredVideoBitrateMbps: Double(sourceVideoBitrate) / 1_000_000,
            bufferSeconds: bufferedPosition.isFinite && sourceTime.isFinite
                ? max(0, bufferedPosition - sourceTime) : nil
        )
    }
}

public struct HybridPlaybackSnapshot: Sendable, Equatable {
    public let phase: HybridPlaybackPhase
    public let route: HybridPlaybackRoute
    public let currentTime: Double
    public let duration: Double
    public let rate: Float
    /// Increments whenever the authoritative audible selection changes,
    /// including native HLS selections that have no FFmpeg stream id yet.
    public let audioSelectionRevision: UInt64
    public let selectedAudioTrackID: Int?
    public let selectedSubtitleTrackID: Int?
    public let audioTracks: [HybridMediaTrack]
    public let subtitleTracks: [HybridMediaTrack]
    public let diagnostics: HybridPlaybackDiagnostics

    public init(
        phase: HybridPlaybackPhase,
        route: HybridPlaybackRoute,
        currentTime: Double,
        duration: Double,
        rate: Float,
        audioSelectionRevision: UInt64 = 0,
        selectedAudioTrackID: Int?,
        selectedSubtitleTrackID: Int?,
        audioTracks: [HybridMediaTrack],
        subtitleTracks: [HybridMediaTrack],
        diagnostics: HybridPlaybackDiagnostics = .init()
    ) {
        self.phase = phase
        self.route = route
        self.currentTime = currentTime
        self.duration = duration
        self.rate = rate
        self.audioSelectionRevision = audioSelectionRevision
        self.selectedAudioTrackID = selectedAudioTrackID
        self.selectedSubtitleTrackID = selectedSubtitleTrackID
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.diagnostics = diagnostics
    }
}

/// Evidence observed by the HLS Proxy Server itself. Segment resolution is
/// scoped to the current seek generation so cancelled, stale requests cannot
/// be mistaken for a successful landing.
public struct HybridHLSProxyServerObservation: Sendable, Equatable {
    public let seekGeneration: UInt64
    public let resolvedSegmentIndices: [Int]

    public init(
        seekGeneration: UInt64,
        resolvedSegmentIndices: [Int]
    ) {
        self.seekGeneration = seekGeneration
        self.resolvedSegmentIndices = resolvedSegmentIndices
    }
}

public enum HybridPlaybackEvent: Sendable, Equatable {
    case snapshot(HybridPlaybackSnapshot)
    case playerBindingChanged(HybridPlaybackRoute)
}

public enum HybridPlaybackError: Error, Sendable, Equatable, LocalizedError {
    case invalidInitialPosition
    case invalidSeekPosition
    case sourceLoadFailed(String)
    case pureAudioUnsupported
    case proxyAssetUnavailable
    case proxyAssetInvalid
    case proxyServerUnavailable(String)
    case proxyDurationUnavailable
    case avKitOverlayUnavailable
    case foregroundRecoveryFailed(String)
    case sessionStopped

    public var errorDescription: String? {
        switch self {
        case .invalidInitialPosition:
            "Initial playback position must be finite and non-negative"
        case .invalidSeekPosition:
            "Seek position must be finite"
        case .sourceLoadFailed(let message):
            "AetherEngine could not load the source: \(message)"
        case .pureAudioUnsupported:
            "SyncnextHybrid V1 does not support pure-audio sessions"
        case .proxyAssetUnavailable:
            "The AVKit proxy asset is missing"
        case .proxyAssetInvalid:
            "The AVKit proxy asset cannot create a finite video item"
        case .proxyServerUnavailable(let message):
            "The AVKit HLS proxy server could not start: \(message)"
        case .proxyDurationUnavailable:
            "The AVKit proxy route requires a confirmed finite VOD duration"
        case .avKitOverlayUnavailable:
            "AVPlayerViewController did not provide a content overlay view"
        case .foregroundRecoveryFailed(let message):
            "Playback could not recover after returning to the foreground: \(message)"
        case .sessionStopped:
            "The playback session has stopped"
        }
    }
}

struct HybridForegroundRecoveryCoordinator {
    struct Recovery: Sendable, Equatable {
        let epoch: UInt64
        let resumeRate: Float?
    }

    enum Phase: Sendable, Equatable {
        case foreground
        case backgrounded(Recovery)
        case recovering(Recovery)
        case failed(Recovery)
        case stopped
    }

    private(set) var phase: Phase = .foreground
    private var nextEpoch: UInt64 = 0

    mutating func enterBackground(resumeRate: Float?) -> Recovery? {
        guard phase != .stopped else {
            return nil
        }
        nextEpoch &+= 1
        let recovery = Recovery(
            epoch: nextEpoch,
            resumeRate: resumeRate
        )
        phase = .backgrounded(recovery)
        return recovery
    }

    mutating func beginForegroundRecovery() -> Recovery? {
        guard case .backgrounded(let recovery) = phase else {
            return nil
        }
        phase = .recovering(recovery)
        return recovery
    }

    mutating func complete(epoch: UInt64) -> Bool {
        guard case .recovering(let recovery) = phase,
              recovery.epoch == epoch else {
            return false
        }
        phase = .foreground
        return true
    }

    mutating func fail(epoch: UInt64) -> Bool {
        guard case .recovering(let recovery) = phase,
              recovery.epoch == epoch else {
            return false
        }
        phase = .failed(recovery)
        return true
    }

    mutating func stop() {
        phase = .stopped
    }
}

enum HybridSeekTargetPolicy {
    static func target(
        requested: Double,
        duration: Double
    ) throws -> Double {
        guard requested.isFinite else {
            throw HybridPlaybackError.invalidSeekPosition
        }

        let nonNegativeTarget = max(0, requested)
        guard duration.isFinite, duration > 0 else {
            return nonNegativeTarget
        }
        return min(nonNegativeTarget, duration)
    }
}
