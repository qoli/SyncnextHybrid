import Foundation

/// A read-only description of the loaded source and its current playback pipeline.
/// Unknown measurements are encoded as null. Source URLs, headers and binary payloads are excluded.
public struct HybridMediaInformation: Codable, Equatable, Sendable {
    public let format: Format
    @HybridMediaNull public var video: Video?
    public let audioTracks: [AudioTrack]
    public let subtitleTracks: [SubtitleTrack]
    public let chapters: [Chapter]
    public let playback: Playback

    public struct Format: Codable, Equatable, Sendable {
        @HybridMediaNull public var name: String?
        @HybridMediaNull public var durationSeconds: Double?
        public let isLive: Bool
        @HybridMediaNull public var title: String?
        @HybridMediaNull public var artist: String?
        @HybridMediaNull public var album: String?
    }

    public struct Video: Codable, Equatable, Sendable {
        @HybridMediaNull public var codec: String?
        @HybridMediaNull public var width: Int?
        @HybridMediaNull public var height: Int?
        @HybridMediaNull public var frameRate: Double?
        @HybridMediaNull public var bitrateBps: Int64?
        @HybridMediaNull public var pixelAspectRatio: Double?
        @HybridMediaNull public var displayAspectRatio: Double?
        public let format: VideoFormat
        @HybridMediaNull public var dynamicRange: String?
        @HybridMediaNull public var dolbyVisionProfile: Int?
    }

    public struct VideoFormat: Codable, Equatable, Sendable {
        @HybridMediaNull public var profile: String?
        @HybridMediaNull public var pixelFormat: String?
        @HybridMediaNull public var bitDepth: Int?
        @HybridMediaNull public var colorPrimaries: String?
        @HybridMediaNull public var transferFunction: String?
        @HybridMediaNull public var colorMatrix: String?
        @HybridMediaNull public var colorRange: String?
    }

    public struct Disposition: Codable, Equatable, Sendable {
        public let isDefault: Bool
        public let isForced: Bool
        public let isHearingImpaired: Bool
        public let isCommentary: Bool
    }

    public struct AudioTrack: Codable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let codec: String
        @HybridMediaNull public var profile: String?
        @HybridMediaNull public var language: String?
        @HybridMediaNull public var sampleRateHz: Int?
        @HybridMediaNull public var channels: Int?
        @HybridMediaNull public var channelLayout: String?
        @HybridMediaNull public var bitsPerSample: Int?
        @HybridMediaNull public var sampleFormat: String?
        @HybridMediaNull public var bitrateBps: Int64?
        /// Positive detection only; false does not prove that object audio is absent.
        public let atmosDetected: Bool
        public let dtsXDetected: Bool
        public let disposition: Disposition
        @HybridMediaNull public var selected: Bool?
    }

    public struct SubtitleTrack: Codable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let codec: String
        @HybridMediaNull public var language: String?
        public let disposition: Disposition
        public let isExternal: Bool
        public let isNativelyRendered: Bool
        @HybridMediaNull public var selected: Bool?
    }

    public struct Chapter: Codable, Equatable, Sendable {
        public let id: Int
        public let title: String
        public let startSeconds: Double
        public let durationSeconds: Double
        /// "playback" for container chapters; "disc-title" for disc chapters.
        public let timeline: String
    }

    public struct Playback: Codable, Equatable, Sendable {
        public let route: String
        public let videoRoute: String
        public let audioDelivery: String
        @HybridMediaNull public var videoDecoder: String?
        @HybridMediaNull public var audioDecoder: String?
        @HybridMediaNull public var displayDynamicRange: String?
        @HybridMediaNull public var dolbyVisionConversion: String?
        @HybridMediaNull public var decodedVideoFormat: VideoFormat?
        @HybridMediaNull public var pixelBufferFormat: String?
        @HybridMediaNull public var selectedAudioTrackID: Int?
        @HybridMediaNull public var selectedSubtitleTrackID: Int?
        @HybridMediaNull public var telemetry: Telemetry?
    }

    public struct Telemetry: Codable, Equatable, Sendable {
        @HybridMediaNull public var instantBitrateBps: Double?
        @HybridMediaNull public var averageBitrateBps: Double?
        @HybridMediaNull public var audioBridgeBitrateBps: Double?
        @HybridMediaNull public var networkThroughputBps: Double?
        @HybridMediaNull public var observedFrameRate: Double?
        @HybridMediaNull public var droppedFrameCount: Int?
        @HybridMediaNull public var forwardBufferSeconds: Double?
        @HybridMediaNull public var displayCushionSeconds: Double?
        @HybridMediaNull public var cachedBytes: Int64?
        @HybridMediaNull public var readerWindowAheadBytes: Int?
        @HybridMediaNull public var avSyncGapMilliseconds: Double?
        public let sourceBytesFetched: Int64
    }
}

/// Keeps unavailable media properties explicit without substituting defaults.
@propertyWrapper
public struct HybridMediaNull<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Value?.self)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(wrappedValue)
    }
}
