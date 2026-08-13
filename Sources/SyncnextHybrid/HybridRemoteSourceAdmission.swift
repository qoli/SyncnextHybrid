import AetherEngine
import CryptoKit
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
    /// A single-variant finite HLS VOD whose master advertises only PQ video
    /// and owns no rendition, key, steering, or timeline contract. AVPlayer
    /// rejects the master on an SDR display route, while the validated media
    /// playlist remains a truthful PQ source and is directly playable.
    case hlsVODPQOnlyMaster(
        mediaPlaylistURL: URL,
        duration: Double
    )
    /// Finite MPEG-TS HLS whose PMT contains positive HEVC evidence.
    /// AetherEngine owns the seekable TS -> fMP4 path.
    case hlsVODHEVCMPEGTS(
        duration: Double,
        evidence: MPEGTransportStreamCodecProbe.HEVCEvidence
    )
    case hlsLive
    case aetherDefault(AetherDefaultReason)

    var isConfirmedHLS: Bool {
        switch self {
        case .hlsVOD, .hlsVODPQOnlyMaster,
             .hlsVODHEVCMPEGTS, .hlsLive:
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
        guard case .hlsVODHEVCMPEGTS(let duration, _) = self else {
            return nil
        }
        return duration
    }

    var diagnosticFields: String {
        switch self {
        case .hlsVOD:
            return "result=hls-vod"
        case .hlsVODPQOnlyMaster(_, let duration):
            return "result=hls-vod-pq-only-master duration="
                + String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    duration
                )
                + " source=resolved-media-playlist"
        case .hlsVODHEVCMPEGTS(let duration, let evidence):
            return "result=hls-vod-hevc-mpegts duration="
                + String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    duration
                )
                + " evidence=\(evidence.diagnosticValue)"
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
                let mediaAdmission = await classifyMedia(
                    media,
                    responseURL: variantCandidate.responseURL,
                    httpHeaders: httpHeaders,
                    session: session
                )
                if case .hlsVOD = mediaAdmission,
                   master.singlePQVideoVariant?.uri == variant.uri {
                    let duration = media.segments.reduce(0) {
                        $0 + $1.duration
                    }
                    guard duration.isFinite, duration > 0 else {
                        return .aetherDefault(.invalidPlaylist)
                    }
                    return .hlsVODPQOnlyMaster(
                        mediaPlaylistURL: variantCandidate.responseURL,
                        duration: duration
                    )
                }
                return mediaAdmission
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
                  (200...299).contains(http.statusCode) else {
                return .hlsVOD
            }
            guard case .hevcInMPEGTS(let evidence) =
                MPEGTransportStreamCodecProbe.classify(data) else {
                return .hlsVOD
            }
            return .hlsVODHEVCMPEGTS(
                duration: duration,
                evidence: evidence
            )
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

struct HybridPlaybackPlan {
    enum SourceResolution: Equatable {
        case original
        case resolvedPQMediaPlaylist
    }

    let url: URL
    let options: LoadOptions
    let sourceResolution: SourceResolution

    static func make(
        request: HybridPlaybackRequest,
        externalSubtitles: [ExternalSubtitleTrack],
        admission: HybridRemoteSourceAdmission
    ) -> Self {
        let url: URL
        let sourceResolution: SourceResolution
        if case .hlsVODPQOnlyMaster(let mediaPlaylistURL, _) = admission {
            url = mediaPlaylistURL
            sourceResolution = .resolvedPQMediaPlaylist
        } else {
            url = request.url
            sourceResolution = .original
        }
        let options = LoadOptions(
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
        return Self(
            url: url,
            options: options,
            sourceResolution: sourceResolution
        )
    }

    var diagnosticFields: String {
        "sourceResolution="
            + {
                switch sourceResolution {
                case .original:
                    "original"
                case .resolvedPQMediaPlaylist:
                    "resolved-pq-media-playlist"
                }
            }()
            + " effectiveSourceID=" + Self.sourceID(url)
    }

    static func sourceID(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Bounded PMT inspection for HEVC MPEG-TS HLS admission. The interface keeps
/// uncertain, non-HEVC, and positively identified HEVC carriage distinct.
enum MPEGTransportStreamCodecProbe {
    private static let packetSize = 188

    enum HEVCEvidence: Equatable {
        case standardStreamType(UInt8)
        case registrationDescriptor(streamType: UInt8)
        case hevcVideoDescriptor(streamType: UInt8)

        var diagnosticValue: String {
            switch self {
            case .standardStreamType(let value):
                "stream-type-\(hex(value))"
            case .registrationDescriptor(let streamType):
                "registration-HEVC-stream-type-\(hex(streamType))"
            case .hevcVideoDescriptor(let streamType):
                "hevc-descriptor-stream-type-\(hex(streamType))"
            }
        }

        private func hex(_ value: UInt8) -> String {
            String(format: "%02X", value)
        }
    }

    enum Verdict: Equatable {
        case hevcInMPEGTS(HEVCEvidence)
        case otherCarriage
        case inconclusive
    }

    static func classify(_ data: Data) -> Verdict {
        let bytes = [UInt8](data)
        guard let syncOffset = (0..<min(packetSize, bytes.count)).first(
            where: { offset in
                offset + packetSize * 2 < bytes.count
                    && bytes[offset] == 0x47
                    && bytes[offset + packetSize] == 0x47
                    && bytes[offset + packetSize * 2] == 0x47
            }
        ) else { return .inconclusive }

        var packetStart = syncOffset
        var sawPMT = false
        while packetStart + packetSize <= bytes.count {
            switch programMapVerdict(bytes, packetStart: packetStart) {
            case .hevcInMPEGTS(let evidence):
                return .hevcInMPEGTS(evidence)
            case .otherCarriage:
                sawPMT = true
            case .inconclusive:
                break
            }
            packetStart += packetSize
        }
        return sawPMT ? .otherCarriage : .inconclusive
    }

    private static func programMapVerdict(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Verdict {
        guard bytes[packetStart] == 0x47,
              bytes[packetStart + 1] & 0x40 != 0 else {
            return .inconclusive
        }
        let packetEnd = packetStart + packetSize
        guard var payload = payloadStart(
            bytes,
            packetStart: packetStart
        ) else { return .inconclusive }
        guard payload < packetEnd else { return .inconclusive }
        payload += 1 + Int(bytes[payload])
        guard payload + 3 <= packetEnd,
              bytes[payload] == 0x02 else {
            return .inconclusive
        }

        let sectionLength =
            (Int(bytes[payload + 1] & 0x0F) << 8)
                | Int(bytes[payload + 2])
        guard sectionLength >= 13 else { return .inconclusive }
        let expectedCount = 3 + sectionLength
        var section = Array(
            bytes[payload..<min(packetEnd, payload + expectedCount)]
        )
        let pid = packetPID(bytes, packetStart: packetStart)
        var continuation = packetStart + packetSize
        while section.count < expectedCount,
              continuation + packetSize <= bytes.count {
            guard bytes[continuation] == 0x47 else { return .inconclusive }
            defer { continuation += packetSize }
            guard packetPID(bytes, packetStart: continuation) == pid,
                  let continuationPayload = payloadStart(
                      bytes,
                      packetStart: continuation
                  ) else { continue }
            let continuationEnd = continuation + packetSize
            if bytes[continuation + 1] & 0x40 != 0 {
                guard continuationPayload < continuationEnd else {
                    return .inconclusive
                }
                let pointer = Int(bytes[continuationPayload])
                let previousSectionEnd = min(
                    continuationEnd,
                    continuationPayload + 1 + pointer
                )
                section.append(
                    contentsOf: bytes[
                        (continuationPayload + 1)..<previousSectionEnd
                    ]
                )
                break
            }
            section.append(
                contentsOf: bytes[continuationPayload..<continuationEnd]
            )
        }
        guard section.count >= expectedCount else { return .inconclusive }
        return classifyProgramMapSection(Array(section.prefix(expectedCount)))
    }

    private static func classifyProgramMapSection(
        _ section: [UInt8]
    ) -> Verdict {
        let sectionEnd = section.count - 4
        let programInfoLength =
            (Int(section[10] & 0x0F) << 8)
                | Int(section[11])
        var stream = 12 + programInfoLength
        guard stream <= sectionEnd else { return .inconclusive }

        var malformedDescriptor = false
        while stream < sectionEnd {
            guard stream + 5 <= sectionEnd else { return .inconclusive }
            let streamType = section[stream]
            if isStandardHEVCStreamType(streamType) {
                return .hevcInMPEGTS(.standardStreamType(streamType))
            }
            let infoLength =
                (Int(section[stream + 3] & 0x0F) << 8)
                    | Int(section[stream + 4])
            let descriptorStart = stream + 5
            let entryEnd = descriptorStart + infoLength
            guard entryEnd <= sectionEnd else { return .inconclusive }
            switch descriptorEvidence(
                section,
                streamType: streamType,
                start: descriptorStart,
                end: entryEnd
            ) {
            case .hevcInMPEGTS(let evidence):
                return .hevcInMPEGTS(evidence)
            case .inconclusive:
                malformedDescriptor = true
            case .otherCarriage:
                break
            }
            stream = entryEnd
        }
        return malformedDescriptor ? .inconclusive : .otherCarriage
    }

    private static func packetPID(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Int {
        (Int(bytes[packetStart + 1] & 0x1F) << 8)
            | Int(bytes[packetStart + 2])
    }

    private static func payloadStart(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Int? {
        let packetEnd = packetStart + packetSize
        let adaptationControl = (bytes[packetStart + 3] >> 4) & 0x03
        switch adaptationControl {
        case 1:
            return packetStart + 4
        case 3:
            let lengthOffset = packetStart + 4
            guard lengthOffset < packetEnd else { return nil }
            let start = lengthOffset + 1 + Int(bytes[lengthOffset])
            return start <= packetEnd ? start : nil
        default:
            return nil
        }
    }

    private static func isStandardHEVCStreamType(_ value: UInt8) -> Bool {
        switch value {
        case 0x24, 0x25, 0x28, 0x29, 0x2A, 0x2B, 0x31:
            true
        default:
            false
        }
    }

    private static func descriptorEvidence(
        _ bytes: [UInt8],
        streamType: UInt8,
        start: Int,
        end: Int
    ) -> Verdict {
        var descriptor = start
        while descriptor < end {
            guard descriptor + 2 <= end else { return .inconclusive }
            let tag = bytes[descriptor]
            let length = Int(bytes[descriptor + 1])
            let payload = descriptor + 2
            let descriptorEnd = payload + length
            guard descriptorEnd <= end else { return .inconclusive }

            if tag == 0x05, length >= 4,
               bytes[payload..<(payload + 4)].elementsEqual([0x48, 0x45, 0x56, 0x43]) {
                return .hevcInMPEGTS(
                    .registrationDescriptor(streamType: streamType)
                )
            }
            if tag == 0x38, length >= 13 {
                return .hevcInMPEGTS(
                    .hevcVideoDescriptor(streamType: streamType)
                )
            }
            descriptor = descriptorEnd
        }
        return .otherCarriage
    }
}
