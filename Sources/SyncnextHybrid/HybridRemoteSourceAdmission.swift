import AetherEngine
import Foundation

/// Content-backed route admission owned by SyncnextHybrid.
///
/// URL suffix and response MIME are never sufficient HLS evidence. A valid
/// media playlist, or a valid master whose selected variant resolves to one,
/// admits Aether's native remote-HLS path. Every inconclusive result preserves
/// the caller-approved fallback to AetherEngine's normal source decision.
enum HybridRemoteSourceAdmission: Equatable {
    enum AetherDefaultReason: Equatable {
        case nonHTTPSource
        case confirmedNonHLS
        case requestFailed
        case invalidHTTPResponse
        case httpStatus(Int)
        case responseTooLarge
        case invalidPlaylist
        case variantUnavailable
    }

    case hlsVOD
    /// Finite MPEG-TS HLS whose PMT declares HEVC (stream_type 0x24).
    /// The temporary AetherEngine patch owns the seekable TS -> fMP4 path.
    case hlsVODHEVCMPEGTS(duration: Double)
    case hlsLive
    case aetherDefault(AetherDefaultReason)

    var isConfirmedHLS: Bool {
        switch self {
        case .hlsVOD, .hlsVODHEVCMPEGTS, .hlsLive:
            true
        case .aetherDefault:
            false
        }
    }

    var isLiveHLS: Bool {
        self == .hlsLive
    }

    var requiresAetherHLSVODRemux: Bool {
        if case .hlsVODHEVCMPEGTS = self {
            return true
        }
        return false
    }

    var avKitProxyDuration: Double? {
        guard case .hlsVODHEVCMPEGTS(let duration) = self else {
            return nil
        }
        return duration
    }

    var diagnosticFields: String {
        switch self {
        case .hlsVOD:
            return "result=hls-vod"
        case .hlsVODHEVCMPEGTS(let duration):
            return "result=hls-vod-hevc-mpegts duration="
                + String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    duration
                )
        case .hlsLive:
            return "result=hls-live"
        case .aetherDefault(let reason):
            return "result=aether-default "
                + reason.diagnosticFields
        }
    }

    static func classify(
        url: URL,
        httpHeaders: [String: String],
        session: URLSession = makeSession()
    ) async throws -> Self {
        guard url.scheme == "http" || url.scheme == "https" else {
            return .aetherDefault(.nonHTTPSource)
        }

        let rootCandidate: PlaylistCandidate
        do {
            guard let candidate = try await fetchPlaylistCandidate(
                url: url,
                httpHeaders: httpHeaders,
                session: session
            ) else {
                return .aetherDefault(.confirmedNonHLS)
            }
            rootCandidate = candidate
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AdmissionProbeError {
            return .aetherDefault(error.reason)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return .aetherDefault(.requestFailed)
        }

        let root: HLSPlaylistDocument
        do {
            root = try HLSPlaylistDocument.parse(rootCandidate.text)
        } catch {
            return .aetherDefault(.invalidPlaylist)
        }

        switch root {
        case .media(let media):
            guard !media.segments.isEmpty else {
                return .aetherDefault(.invalidPlaylist)
            }
            return await classifyMedia(
                media,
                responseURL: rootCandidate.responseURL,
                httpHeaders: httpHeaders,
                session: session
            )

        case .master(let master):
            guard let variant = master.variants.max(
                by: { lhs, rhs in
                    if lhs.bandwidth == rhs.bandwidth {
                        return lhs.uri > rhs.uri
                    }
                    return lhs.bandwidth < rhs.bandwidth
                }
            ), let variantURL = URL(
                string: variant.uri,
                relativeTo: rootCandidate.responseURL
            )?.absoluteURL else {
                return .aetherDefault(.variantUnavailable)
            }

            let variantCandidate: PlaylistCandidate
            do {
                guard let candidate = try await fetchPlaylistCandidate(
                    url: variantURL,
                    httpHeaders: httpHeaders,
                    session: session
                ) else {
                    return .aetherDefault(.variantUnavailable)
                }
                variantCandidate = candidate
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                return .aetherDefault(.variantUnavailable)
            }

            do {
                guard case .media(let media) =
                    try HLSPlaylistDocument.parse(
                        variantCandidate.text
                    ),
                    !media.segments.isEmpty else {
                    return .aetherDefault(.variantUnavailable)
                }
                return await classifyMedia(
                    media,
                    responseURL: variantCandidate.responseURL,
                    httpHeaders: httpHeaders,
                    session: session
                )
            } catch {
                return .aetherDefault(.variantUnavailable)
            }
        }
    }

    private static let maximumPlaylistBytes = 2 * 1024 * 1024
    private static let maximumLeadingWhitespaceBytes = 1024
    private static let codecProbeBytes = 512 * 1024

    private static func classifyMedia(
        _ media: HLSMediaDocument,
        responseURL: URL,
        httpHeaders: [String: String],
        session: URLSession
    ) async -> Self {
        guard media.hasEndList else {
            return .hlsLive
        }
        let duration = media.segments.reduce(0) {
            $0 + $1.duration
        }
        guard duration.isFinite, duration > 0 else {
            return .aetherDefault(.invalidPlaylist)
        }
        guard media.segments.first?.map == nil,
              let uri = media.segments.first?.resource.uri,
              let segmentURL = URL(
                  string: uri,
                  relativeTo: responseURL
              )?.absoluteURL else {
            return .hlsVOD
        }

        var request = URLRequest(url: segmentURL)
        for (name, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(
            "bytes=0-\(codecProbeBytes - 1)",
            forHTTPHeaderField: "Range"
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  MPEGTransportStreamCodecProbe.containsHEVC(data) else {
                return .hlsVOD
            }
            return .hlsVODHEVCMPEGTS(duration: duration)
        } catch {
            return .hlsVOD
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy =
            .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static func fetchPlaylistCandidate(
        url: URL,
        httpHeaders: [String: String],
        session: URLSession
    ) async throws -> PlaylistCandidate? {
        var request = URLRequest(url: url)
        for (name, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(
            "bytes=0-\(maximumPlaylistBytes)",
            forHTTPHeaderField: "Range"
        )

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw AdmissionProbeError(reason: .requestFailed)
        }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw AdmissionProbeError(reason: .invalidHTTPResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw AdmissionProbeError(
                reason: .httpStatus(http.statusCode)
            )
        }

        var data = Data()
        var prefixState = PlaylistPrefixState.incomplete
        do {
            for try await byte in bytes {
                guard data.count < maximumPlaylistBytes else {
                    throw AdmissionProbeError(
                        reason: .responseTooLarge
                    )
                }
                data.append(byte)
                if prefixState == .incomplete {
                    prefixState = playlistPrefixState(data)
                    if prefixState == .notHLS {
                        return nil
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AdmissionProbeError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw AdmissionProbeError(reason: .requestFailed)
        }

        guard prefixState == .hls,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return PlaylistCandidate(
            text: text,
            responseURL: http.url ?? url
        )
    }

    private enum PlaylistPrefixState {
        case incomplete
        case hls
        case notHLS
    }

    private static func playlistPrefixState(
        _ data: Data
    ) -> PlaylistPrefixState {
        let bytes = [UInt8](data)
        var index = 0

        if bytes.first == 0xEF {
            guard bytes.count >= 3 else {
                return .incomplete
            }
            guard bytes[1] == 0xBB, bytes[2] == 0xBF else {
                return .notHLS
            }
            index = 3
        }

        while index < bytes.count,
              bytes[index] == 0x20
                || bytes[index] == 0x09
                || bytes[index] == 0x0A
                || bytes[index] == 0x0D {
            index += 1
            if index > maximumLeadingWhitespaceBytes {
                return .notHLS
            }
        }

        let tag = Array("#EXTM3U".utf8)
        let available = bytes.count - index
        guard available > 0 else {
            return .incomplete
        }
        let compared = min(available, tag.count)
        guard Array(bytes[index..<(index + compared)])
                == Array(tag.prefix(compared)) else {
            return .notHLS
        }
        return available >= tag.count ? .hls : .incomplete
    }

    private struct PlaylistCandidate {
        let text: String
        let responseURL: URL
    }
}

private extension HybridRemoteSourceAdmission.AetherDefaultReason {
    var diagnosticFields: String {
        switch self {
        case .nonHTTPSource:
            return "reason=non-http-source"
        case .confirmedNonHLS:
            return "reason=confirmed-non-hls"
        case .requestFailed:
            return "reason=request-failed"
        case .invalidHTTPResponse:
            return "reason=invalid-http-response"
        case .httpStatus(let status):
            return "reason=http-status status=\(status)"
        case .responseTooLarge:
            return "reason=response-too-large"
        case .invalidPlaylist:
            return "reason=invalid-playlist"
        case .variantUnavailable:
            return "reason=variant-unavailable"
        }
    }
}

enum HybridProxyDurationPolicy {
    static func duration(
        admission: HybridRemoteSourceAdmission,
        engineDuration: Double
    ) throws -> Double {
        guard admission.requiresAetherHLSVODRemux else {
            return engineDuration
        }
        guard let duration = admission.avKitProxyDuration,
              duration.isFinite,
              duration > 0 else {
            throw HybridPlaybackError.proxyDurationUnavailable
        }
        return duration
    }
}

private struct AdmissionProbeError: Error {
    let reason: HybridRemoteSourceAdmission.AetherDefaultReason
}

enum HybridPlaybackLoadOptions {
    static func make(
        request: HybridPlaybackRequest,
        externalSubtitles: [ExternalSubtitleTrack],
        admission: HybridRemoteSourceAdmission
    ) -> LoadOptions {
        LoadOptions(
            httpHeaders: request.httpHeaders,
            isLive: admission.isLiveHLS,
            nativeRemoteHLS:
                admission.isConfirmedHLS
                    && !admission.requiresAetherHLSVODRemux,
            preferredAudioLanguages: request.preferredAudioLanguages,
            preferredSubtitleLanguages:
                request.preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            autoplay: false
        )
    }
}

/// Bounded PMT inspection used only by the disposable HEVC MPEG-TS HLS
/// workaround. It never guesses from a URL suffix or MIME type.
enum MPEGTransportStreamCodecProbe {
    private static let packetSize = 188

    static func containsHEVC(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard let syncOffset = (0..<min(packetSize, bytes.count)).first(
            where: { offset in
                offset + packetSize * 2 < bytes.count
                    && bytes[offset] == 0x47
                    && bytes[offset + packetSize] == 0x47
                    && bytes[offset + packetSize * 2] == 0x47
            }
        ) else {
            return false
        }

        var packetStart = syncOffset
        while packetStart + packetSize <= bytes.count {
            if packetContainsHEVC(
                bytes,
                packetStart: packetStart
            ) {
                return true
            }
            packetStart += packetSize
        }
        return false
    }

    private static func packetContainsHEVC(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Bool {
        guard bytes[packetStart] == 0x47,
              bytes[packetStart + 1] & 0x40 != 0 else {
            return false
        }
        let adaptationControl = (bytes[packetStart + 3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else {
            return false
        }
        var payload = packetStart + 4
        if adaptationControl == 3 {
            payload += 1 + Int(bytes[payload])
        }
        let packetEnd = packetStart + packetSize
        guard payload < packetEnd else {
            return false
        }
        payload += 1 + Int(bytes[payload])
        guard payload + 12 <= packetEnd,
              bytes[payload] == 0x02 else {
            return false
        }

        let sectionLength =
            (Int(bytes[payload + 1] & 0x0F) << 8)
                | Int(bytes[payload + 2])
        let sectionEnd = min(packetEnd, payload + 3 + sectionLength - 4)
        let programInfoLength =
            (Int(bytes[payload + 10] & 0x0F) << 8)
                | Int(bytes[payload + 11])
        var stream = payload + 12 + programInfoLength
        while stream + 5 <= sectionEnd {
            if bytes[stream] == 0x24 {
                return true
            }
            let infoLength =
                (Int(bytes[stream + 3] & 0x0F) << 8)
                    | Int(bytes[stream + 4])
            stream += 5 + infoLength
        }
        return false
    }
}
