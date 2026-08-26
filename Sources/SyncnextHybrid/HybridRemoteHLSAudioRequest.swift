import Foundation

/// Stable, non-AVFoundation description of the audible option selected by a
/// probe-free native HLS item.
public struct HybridRemoteHLSAudioSelection: Sendable, Equatable {
    public let displayName: String?
    public let language: String?
    public let optionOrdinal: Int?

    public init(
        displayName: String?,
        language: String?,
        optionOrdinal: Int?
    ) {
        self.displayName = displayName
        self.language = language
        self.optionOrdinal = optionOrdinal
    }
}

/// Everything Hybrid needs to prepare an independent finite HLS VOD cursor.
/// The request contains no AVPlayer or AVMediaSelectionOption objects.
public struct HybridRemoteHLSAudioRequest: Sendable, Equatable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let selection: HybridRemoteHLSAudioSelection

    public init(
        url: URL,
        httpHeaders: [String: String],
        selection: HybridRemoteHLSAudioSelection
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.selection = selection
    }
}
