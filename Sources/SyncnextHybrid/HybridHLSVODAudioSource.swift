import AetherEngine
import Foundation

struct HybridHLSPreparedAudioCursor {
    let reader: IOReader
    let formatHint: String
    let selection: AetherRemoteHLSAudioSelection
    let usesDedicatedAudioRendition: Bool

    func close() {
        reader.close()
    }
}

enum HybridHLSVODAudioSource {
    private static let maximumPlaylistBytes = 2 * 1024 * 1024
    private static let maximumAssembledBytes: Int64 =
        2 * 1024 * 1024 * 1024
    private static let maximumConcurrentResourceRequests = 4

    static func prepare(
        request: AetherRemoteHLSAudioRequest,
        range: Range<Double>,
        session: URLSession = makeSession()
    ) async throws -> HybridHLSPreparedAudioCursor {
        let rootText = try await fetchPlaylist(
            request.url,
            headers: request.httpHeaders,
            session: session
        )

        let mediaURL: URL
        let usesDedicatedAudioRendition: Bool
        switch try HLSPlaylistDocument.parse(rootText) {
        case .media:
            mediaURL = request.url
            usesDedicatedAudioRendition = false
        case .master(let master):
            let resolved = try master.resolveAudioPlaylist(
                baseURL: request.url,
                selection: request.selection
            )
            mediaURL = resolved.url
            usesDedicatedAudioRendition =
                resolved.usesDedicatedAudioRendition
        }

        let mediaText: String
        if mediaURL == request.url {
            mediaText = rootText
        } else {
            mediaText = try await fetchPlaylist(
                mediaURL,
                headers: request.httpHeaders,
                session: session
            )
        }
        guard case .media(let media) =
            try HLSPlaylistDocument.parse(mediaText) else {
            throw HybridAudioAnalysisError.demuxFailed(
                "selected HLS audio URI did not resolve to a media playlist"
            )
        }
        guard media.hasEndList else {
            throw HybridAudioAnalysisError.liveOrDVRUnsupported
        }
        guard !media.segments.isEmpty else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS VOD media playlist contains no segments"
            )
        }
        guard media.totalDuration + 0.001 >= range.upperBound else {
            throw HybridAudioAnalysisError.rangeOutsideSource
        }

        let selectedSegments = media.prefix(through: range.upperBound)
        let reader = HybridHLSVODResourceReader()
        var resources: [HLSByteResource] = []
        var lastMap: HLSByteResource?
        for segment in selectedSegments {
            if let map = segment.map, map != lastMap {
                resources.append(map)
                lastMap = map
            }
            resources.append(segment.resource)
        }
        let producer = Task.detached(priority: .utility) {
            do {
                var writtenBytes: Int64 = 0
                for batchStart in stride(
                    from: 0,
                    to: resources.count,
                    by: maximumConcurrentResourceRequests
                ) {
                    try Task.checkCancellation()
                    let batchEnd = min(
                        batchStart + maximumConcurrentResourceRequests,
                        resources.count
                    )
                    let batch = Array(resources[batchStart..<batchEnd])
                    let fetched = try await fetchBatch(
                        batch,
                        relativeTo: mediaURL,
                        headers: request.httpHeaders,
                        session: session
                    )
                    for bytes in fetched {
                        writtenBytes += Int64(bytes.count)
                        guard writtenBytes <= maximumAssembledBytes else {
                            throw HybridAudioAnalysisError.demuxFailed(
                                "bounded HLS VOD analysis input exceeded 2 GiB"
                            )
                        }
                        try reader.append(bytes)
                    }
                }
                reader.finish()
            } catch {
                reader.fail()
            }
        }
        reader.install(producer: producer)

        return HybridHLSPreparedAudioCursor(
            reader: reader,
            formatHint: media.formatHint,
            selection: request.selection,
            usesDedicatedAudioRendition:
                usesDedicatedAudioRendition
        )
    }

    static func resolveSelectedTrack(
        from tracks: [TrackInfo],
        prepared: HybridHLSPreparedAudioCursor
    ) throws -> TrackInfo {
        guard !tracks.isEmpty else {
            throw HybridAudioAnalysisError.selectedAudioTrackUnavailable
        }
        if prepared.usesDedicatedAudioRendition {
            guard tracks.count == 1 else {
                throw HybridAudioAnalysisError.sourceTrackChanged
            }
            return tracks[0]
        }

        let selection = prepared.selection
        if let ordinal = selection.optionOrdinal {
            guard tracks.indices.contains(ordinal) else {
                throw HybridAudioAnalysisError.sourceTrackChanged
            }
            let track = tracks[ordinal]
            if let language = selection.language,
               let trackLanguage = track.language,
               normalize(language) != normalize(trackLanguage) {
                throw HybridAudioAnalysisError.sourceTrackChanged
            }
            return track
        }

        if let language = selection.language {
            let matches = tracks.filter {
                $0.language.map(normalize) == normalize(language)
            }
            guard matches.count == 1 else {
                throw HybridAudioAnalysisError.selectedAudioTrackUnavailable
            }
            return matches[0]
        }

        if tracks.count == 1 {
            return tracks[0]
        }
        let defaults = tracks.filter(\.isDefault)
        guard defaults.count == 1 else {
            throw HybridAudioAnalysisError.selectedAudioTrackUnavailable
        }
        return defaults[0]
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy =
            .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static func fetchPlaylist(
        _ url: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> String {
        let data = try await fetch(
            url,
            headers: headers,
            byteRange: nil,
            session: session
        )
        guard data.count <= maximumPlaylistBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS playlist is not bounded UTF-8 text"
            )
        }
        return text
    }

    private static func fetchResource(
        _ resource: HLSByteResource,
        relativeTo baseURL: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(
            string: resource.uri,
            relativeTo: baseURL
        )?.absoluteURL else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS VOD contains an invalid resource URI"
            )
        }
        return try await fetch(
            url,
            headers: headers,
            byteRange: resource.byteRange,
            session: session
        )
    }

    private static func fetchBatch(
        _ resources: [HLSByteResource],
        relativeTo baseURL: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> [Data] {
        try await withThrowingTaskGroup(
            of: (Int, Data).self,
            returning: [Data].self
        ) { group in
            for (index, resource) in resources.enumerated() {
                group.addTask {
                    (
                        index,
                        try await fetchResource(
                            resource,
                            relativeTo: baseURL,
                            headers: headers,
                            session: session
                        )
                    )
                }
            }

            var fetched = Array<Data?>(
                repeating: nil,
                count: resources.count
            )
            for try await (index, data) in group {
                fetched[index] = data
            }
            return try fetched.map {
                guard let data = $0 else {
                    throw HybridAudioAnalysisError.demuxFailed(
                        "HLS VOD resource batch was incomplete"
                    )
                }
                return data
            }
        }
    }

    private static func fetch(
        _ url: URL,
        headers: [String: String],
        byteRange: HLSByteRange?,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let byteRange {
            request.setValue(
                "bytes=\(byteRange.offset)-\(byteRange.endOffset - 1)",
                forHTTPHeaderField: "Range"
            )
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw HybridAudioAnalysisError.cancelled
        } catch {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS VOD resource request failed"
            )
        }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS VOD resource returned a non-success status"
            )
        }
        guard let byteRange, http.statusCode != 206 else {
            return data
        }
        guard byteRange.endOffset <= data.count else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS byte-range response was shorter than declared"
            )
        }
        return data.subdata(
            in: byteRange.offset..<byteRange.endOffset
        )
    }

    fileprivate static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}

enum HLSPlaylistDocument {
    case master(HLSMasterDocument)
    case media(HLSMediaDocument)

    static func parse(_ text: String) throws -> Self {
        let normalizedText = text.hasPrefix("\u{FEFF}")
            ? String(text.dropFirst())
            : text
        let lines = normalizedText
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS playlist is missing EXTM3U"
            )
        }
        if lines.contains(
            where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        ) {
            return .master(try HLSMasterDocument(lines: lines))
        }
        return .media(try HLSMediaDocument(lines: lines))
    }
}

struct HLSMasterDocument {
    struct Variant {
        let bandwidth: Int
        let uri: String
        let audioGroupID: String?
    }

    struct Rendition {
        let groupID: String
        let name: String?
        let language: String?
        let uri: String?
        let isDefault: Bool
    }

    let variants: [Variant]
    let renditions: [Rendition]

    init(lines: [String]) throws {
        var variants: [Variant] = []
        var renditions: [Rendition] = []
        var pendingBandwidth: Int?
        var pendingAudioGroupID: String?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth =
                    HLSAttributeParser.value(
                        "BANDWIDTH",
                        in: line
                    ).flatMap(Int.init) ?? 0
                pendingAudioGroupID =
                    HLSAttributeParser.value("AUDIO", in: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:"),
                      HLSAttributeParser.value("TYPE", in: line)
                        == "AUDIO",
                      let groupID = HLSAttributeParser.value(
                        "GROUP-ID",
                        in: line
                      ) {
                renditions.append(
                    Rendition(
                        groupID: groupID,
                        name: HLSAttributeParser.value(
                            "NAME",
                            in: line
                        ),
                        language: HLSAttributeParser.value(
                            "LANGUAGE",
                            in: line
                        ),
                        uri: HLSAttributeParser.value(
                            "URI",
                            in: line
                        ),
                        isDefault:
                            HLSAttributeParser.value(
                                "DEFAULT",
                                in: line
                            ) == "YES"
                    )
                )
            } else if !line.hasPrefix("#"),
                      let bandwidth = pendingBandwidth {
                variants.append(
                    Variant(
                        bandwidth: bandwidth,
                        uri: line,
                        audioGroupID: pendingAudioGroupID
                    )
                )
                pendingBandwidth = nil
                pendingAudioGroupID = nil
            }
        }
        guard !variants.isEmpty else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS master playlist contains no variants"
            )
        }
        self.variants = variants
        self.renditions = renditions
    }

    func resolveAudioPlaylist(
        baseURL: URL,
        selection: AetherRemoteHLSAudioSelection
    ) throws -> (
        url: URL,
        usesDedicatedAudioRendition: Bool
    ) {
        guard let variant = variants.max(
            by: { lhs, rhs in
                if lhs.bandwidth == rhs.bandwidth {
                    return lhs.uri > rhs.uri
                }
                return lhs.bandwidth < rhs.bandwidth
            }
        ) else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS master playlist contains no usable variant"
            )
        }

        if let groupID = variant.audioGroupID {
            let group = renditions.filter {
                $0.groupID == groupID
            }
            if !group.isEmpty {
                let rendition = try resolveRendition(
                    group,
                    selection: selection
                )
                if let uri = rendition.uri {
                    guard let url = URL(
                        string: uri,
                        relativeTo: baseURL
                    )?.absoluteURL else {
                        throw HybridAudioAnalysisError.demuxFailed(
                            "selected HLS audio rendition has an invalid URI"
                        )
                    }
                    return (url, true)
                }
            }
        }

        guard let url = URL(
            string: variant.uri,
            relativeTo: baseURL
        )?.absoluteURL else {
            throw HybridAudioAnalysisError.demuxFailed(
                "selected HLS variant has an invalid URI"
            )
        }
        return (url, false)
    }

    private func resolveRendition(
        _ group: [Rendition],
        selection: AetherRemoteHLSAudioSelection
    ) throws -> Rendition {
        if let ordinal = selection.optionOrdinal {
            guard group.indices.contains(ordinal) else {
                throw HybridAudioAnalysisError.sourceTrackChanged
            }
            let rendition = group[ordinal]
            if let language = selection.language,
               rendition.language.map(
                   HybridHLSVODAudioSource.normalize
               ) != HybridHLSVODAudioSource.normalize(language) {
                throw HybridAudioAnalysisError.sourceTrackChanged
            }
            return rendition
        }

        let matches = group.filter { rendition in
            let nameMatches = selection.displayName.map {
                rendition.name?.caseInsensitiveCompare($0)
                    == .orderedSame
            } ?? true
            let languageMatches = selection.language.map {
                rendition.language.map(
                    HybridHLSVODAudioSource.normalize
                ) == HybridHLSVODAudioSource.normalize($0)
            } ?? true
            return nameMatches && languageMatches
        }
        if selection.displayName != nil || selection.language != nil {
            guard matches.count == 1 else {
                throw HybridAudioAnalysisError
                    .selectedAudioTrackUnavailable
            }
            return matches[0]
        }

        let defaults = group.filter(\.isDefault)
        if defaults.count == 1 {
            return defaults[0]
        }
        guard group.count == 1 else {
            throw HybridAudioAnalysisError
                .selectedAudioTrackUnavailable
        }
        return group[0]
    }
}

struct HLSMediaDocument {
    let segments: [HLSSegmentDocument]
    let hasEndList: Bool
    let totalDuration: Double

    init(lines: [String]) throws {
        var segments: [HLSSegmentDocument] = []
        var hasEndList = false
        var pendingDuration: Double?
        var pendingByteRange: HLSByteRange?
        var activeMap: HLSByteResource?
        var previousRangeEndByURI: [String: Int] = [:]

        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                let payload = line.dropFirst("#EXTINF:".count)
                pendingDuration = Double(
                    payload.split(separator: ",").first.map(String.init)
                        ?? ""
                )
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = try HLSByteRange.parse(
                    String(
                        line.dropFirst(
                            "#EXT-X-BYTERANGE:".count
                        )
                    ),
                    implicitOffset: nil
                )
            } else if line.hasPrefix("#EXT-X-MAP:") {
                guard let uri = HLSAttributeParser.value(
                    "URI",
                    in: line
                ) else {
                    throw HybridAudioAnalysisError.demuxFailed(
                        "HLS initialization map is missing a URI"
                    )
                }
                let range = try HLSAttributeParser.value(
                    "BYTERANGE",
                    in: line
                ).map {
                    try HLSByteRange.parse(
                        $0,
                        implicitOffset:
                            previousRangeEndByURI[uri]
                    )
                }
                if let range {
                    previousRangeEndByURI[uri] = range.endOffset
                }
                activeMap = HLSByteResource(
                    uri: uri,
                    byteRange: range
                )
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method =
                    HLSAttributeParser.value("METHOD", in: line)
                    ?? "NONE"
                guard method == "NONE" else {
                    throw HybridAudioAnalysisError.demuxFailed(
                        "encrypted HLS VOD analysis is unsupported"
                    )
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                let implicitOffset = previousRangeEndByURI[line]
                let range: HLSByteRange?
                if let pendingByteRange {
                    range = HLSByteRange(
                        length: pendingByteRange.length,
                        offset:
                            pendingByteRange.offsetWasExplicit
                            ? pendingByteRange.offset
                            : (implicitOffset ?? 0),
                        offsetWasExplicit:
                            pendingByteRange.offsetWasExplicit
                    )
                } else {
                    range = nil
                }
                if let range {
                    previousRangeEndByURI[line] = range.endOffset
                }
                segments.append(
                    HLSSegmentDocument(
                        duration: pendingDuration ?? 0,
                        resource: HLSByteResource(
                            uri: line,
                            byteRange: range
                        ),
                        map: activeMap
                    )
                )
                pendingDuration = nil
                pendingByteRange = nil
            }
        }
        guard segments.allSatisfy({
            $0.duration.isFinite && $0.duration > 0
        }) else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS VOD contains a segment without a positive duration"
            )
        }
        self.segments = segments
        self.hasEndList = hasEndList
        totalDuration = segments.reduce(0) {
            $0 + $1.duration
        }
    }

    func prefix(through upperBound: Double)
        -> ArraySlice<HLSSegmentDocument>
    {
        var duration = 0.0
        var endIndex = segments.startIndex
        for index in segments.indices {
            duration += segments[index].duration
            endIndex = segments.index(after: index)
            if duration + 0.001 >= upperBound {
                break
            }
        }
        return segments[..<endIndex]
    }

    var fileExtension: String {
        if segments.contains(where: { $0.map != nil }) {
            return "mp4"
        }
        let pathExtension =
            URL(string: segments[0].resource.uri)?
                .pathExtension.lowercased()
        switch pathExtension {
        case "aac", "ac3", "eac3", "m4a", "mp3", "ts", "m2ts":
            return pathExtension!
        default:
            return "bin"
        }
    }

    var formatHint: String {
        switch fileExtension {
        case "ts", "m2ts":
            return "mpegts"
        case "mp4", "m4a":
            return "mov"
        default:
            return fileExtension
        }
    }
}

struct HLSSegmentDocument {
    let duration: Double
    let resource: HLSByteResource
    let map: HLSByteResource?
}

struct HLSByteResource: Equatable, Sendable {
    let uri: String
    let byteRange: HLSByteRange?
}

struct HLSByteRange: Equatable, Sendable {
    let length: Int
    let offset: Int
    let offsetWasExplicit: Bool

    var endOffset: Int {
        offset + length
    }

    static func parse(
        _ raw: String,
        implicitOffset: Int?
    ) throws -> Self {
        let components = raw.split(
            separator: "@",
            maxSplits: 1
        )
        guard let length = components.first.flatMap({
            Int($0)
        }), length > 0 else {
            throw HybridAudioAnalysisError.demuxFailed(
                "HLS byte range has an invalid length"
            )
        }
        if components.count == 2 {
            guard let offset = Int(components[1]), offset >= 0 else {
                throw HybridAudioAnalysisError.demuxFailed(
                    "HLS byte range has an invalid offset"
                )
            }
            return Self(
                length: length,
                offset: offset,
                offsetWasExplicit: true
            )
        }
        return Self(
            length: length,
            offset: implicitOffset ?? 0,
            offsetWasExplicit: false
        )
    }
}

private final class HybridHLSVODResourceReader:
    IOReader,
    @unchecked Sendable
{
    private static let maximumBufferedBytes = 32 * 1024 * 1024

    private let condition = NSCondition()
    private var queue: [Data] = []
    private var headOffset = 0
    private var bufferedBytes = 0
    private var position: Int64 = 0
    private var finished = false
    private var failed = false
    private var closed = false
    private var producer: Task<Void, Never>?

    func install(producer: Task<Void, Never>) {
        condition.lock()
        self.producer = producer
        let shouldCancel = closed
        condition.unlock()
        if shouldCancel {
            producer.cancel()
        }
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else {
            return
        }
        condition.lock()
        defer { condition.unlock() }
        while !closed,
              bufferedBytes > 0,
              bufferedBytes + data.count > Self.maximumBufferedBytes {
            condition.wait()
        }
        guard !closed else {
            throw HybridAudioAnalysisError.cancelled
        }
        queue.append(data)
        bufferedBytes += data.count
        condition.broadcast()
    }

    func finish() {
        condition.lock()
        finished = true
        producer = nil
        condition.broadcast()
        condition.unlock()
    }

    func fail() {
        condition.lock()
        failed = true
        producer = nil
        condition.broadcast()
        condition.unlock()
    }

    func read(
        _ buffer: UnsafeMutablePointer<UInt8>?,
        size: Int32
    ) -> Int32 {
        guard let buffer, size > 0 else {
            return -1
        }
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !finished, !failed, !closed {
            condition.wait()
        }
        guard !queue.isEmpty else {
            return finished ? 0 : -1
        }

        let available = queue[0].count - headOffset
        let count = min(available, Int(size))
        queue[0].withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            buffer.update(
                from: baseAddress
                    .assumingMemoryBound(to: UInt8.self)
                    .advanced(by: headOffset),
                count: count
            )
        }
        headOffset += count
        bufferedBytes -= count
        position += Int64(count)
        if headOffset == queue[0].count {
            queue.removeFirst()
            headOffset = 0
        }
        condition.broadcast()
        return Int32(count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == SEEK_CUR, offset == 0 {
            condition.lock()
            defer { condition.unlock() }
            return position
        }
        return -1
    }

    func cancel() {
        close()
    }

    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        let producer = producer
        self.producer = nil
        queue.removeAll()
        bufferedBytes = 0
        condition.broadcast()
        condition.unlock()
        producer?.cancel()
    }

    func makeIndependentReader() -> IOReader? {
        nil
    }
}

enum HLSAttributeParser {
    static func value(
        _ key: String,
        in line: String
    ) -> String? {
        let needle = "\(key)="
        var searchStart = line.startIndex
        while let range = line.range(
            of: needle,
            range: searchStart..<line.endIndex
        ) {
            searchStart = range.upperBound
            if range.lowerBound != line.startIndex {
                let before = line[
                    line.index(before: range.lowerBound)
                ]
                guard before == ":" || before == "," else {
                    continue
                }
            }
            let quotesBefore = line[
                line.startIndex..<range.lowerBound
            ].reduce(0) {
                $1 == "\"" ? $0 + 1 : $0
            }
            guard quotesBefore.isMultiple(of: 2) else {
                continue
            }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("\"") {
                let afterQuote = rest.dropFirst()
                guard let end = afterQuote.firstIndex(of: "\"") else {
                    return nil
                }
                return String(afterQuote[..<end])
            }
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }
}
