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
    case hlsLive
    case aetherDefault(AetherDefaultReason)

    var isConfirmedHLS: Bool {
        switch self {
        case .hlsVOD, .hlsLive:
            true
        case .aetherDefault:
            false
        }
    }

    var isLiveHLS: Bool {
        self == .hlsLive
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
            return media.hasEndList ? .hlsVOD : .hlsLive

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
                return media.hasEndList ? .hlsVOD : .hlsLive
            } catch {
                return .aetherDefault(.variantUnavailable)
            }
        }
    }

    private static let maximumPlaylistBytes = 2 * 1024 * 1024
    private static let maximumLeadingWhitespaceBytes = 1024

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
            nativeRemoteHLS: admission.isConfirmedHLS,
            preferredAudioLanguages: request.preferredAudioLanguages,
            preferredSubtitleLanguages:
                request.preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            autoplay: false
        )
    }
}
