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
    public let initialPosition: Double?
    public let externalSubtitles: [HybridExternalSubtitle]
    public let preferredAudioLanguages: [String]
    public let preferredSubtitleLanguages: [String]

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
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
        self.initialPosition = initialPosition
        self.externalSubtitles = externalSubtitles
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
    }
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
        isCommentary: Bool
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
    }
}

public enum HybridPlaybackRoute: Sendable, Equatable {
    /// AVKit owns the same native AVPlayer instance published by AetherEngine.
    case nativeAVPlayer
    /// AVKit owns a silent black UI proxy while AetherEngine renders and clocks.
    case avKitProxy
}

public enum HybridPlaybackPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled
    case ended
    case failed(String)
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
        subtitleTracks: [HybridMediaTrack]
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
    }
}

public enum HybridPlaybackEvent: Sendable, Equatable {
    case snapshot(HybridPlaybackSnapshot)
    case playerBindingChanged(HybridPlaybackRoute)
    case audioAnalysisUnavailable(HybridAudioAnalysisError)
}

public enum HybridPlaybackError: Error, Sendable, Equatable, LocalizedError {
    case invalidInitialPosition
    case sourceLoadFailed(String)
    case pureAudioUnsupported
    case proxyAssetUnavailable
    case proxyAssetInvalid
    case avKitOverlayUnavailable
    case sessionStopped

    public var errorDescription: String? {
        switch self {
        case .invalidInitialPosition:
            "Initial playback position must be finite and non-negative"
        case .sourceLoadFailed(let message):
            "AetherEngine could not load the source: \(message)"
        case .pureAudioUnsupported:
            "SyncnextHybrid V1 does not support pure-audio sessions"
        case .proxyAssetUnavailable:
            "The AVKit proxy asset is missing"
        case .proxyAssetInvalid:
            "The AVKit proxy asset cannot create a finite video item"
        case .avKitOverlayUnavailable:
            "AVPlayerViewController did not provide a content overlay view"
        case .sessionStopped:
            "The playback session has stopped"
        }
    }
}
