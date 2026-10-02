import Foundation
import Network

/// The authorized fallback changes only an undersized target duration in a
/// finite media playlist. Resource URLs keep their original origin and headers.
struct HybridHLSManifestRepair: Equatable, Sendable {
    let playlist: String
    let originalTargetDuration: Int
    let correctedTargetDuration: Int
    let maximumSegmentDuration: Double

    static func make(
        text: String,
        media: HLSMediaDocument,
        responseURL: URL
    ) throws -> Self? {
        guard media.hasEndList,
              let maximum = media.segments.map(\.duration).max(),
              maximum.isFinite, maximum > 0 else {
            return nil
        }
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("\u{FEFF}") {
            source.removeFirst()
            source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = source.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ).map { String($0).trimmingCharacters(in: .whitespaces) }
        let targetIndexes = lines.indices.filter {
            lines[$0].hasPrefix("#EXT-X-TARGETDURATION:")
        }
        guard targetIndexes.count == 1,
              let index = targetIndexes.first,
              let original = Int(
                  lines[index].dropFirst("#EXT-X-TARGETDURATION:".count)
              ), original > 0,
              maximum.rounded() > Double(original) else {
            return nil
        }
        guard let corrected = Int(exactly: maximum.rounded(.up)) else {
            throw HybridHLSManifestFallbackError.unrepresentableDuration
        }
        lines[index] = "#EXT-X-TARGETDURATION:\(corrected)"
        let uriAttribute = try NSRegularExpression(
            pattern: #"(?<=[:,])URI="([^"]*)""#
        )
        for lineIndex in lines.indices {
            let line = lines[lineIndex]
            if !line.isEmpty, !line.hasPrefix("#") {
                lines[lineIndex] = try absoluteURI(line, baseURL: responseURL)
            } else {
                let source = line as NSString
                let rewritten = NSMutableString(string: line)
                for match in uriAttribute.matches(
                    in: line,
                    range: NSRange(location: 0, length: source.length)
                ).reversed() {
                    let range = match.range(at: 1)
                    rewritten.replaceCharacters(
                        in: range,
                        with: try absoluteURI(
                            source.substring(with: range),
                            baseURL: responseURL
                        )
                    )
                }
                lines[lineIndex] = rewritten as String
            }
        }
        return Self(
            playlist: lines.joined(separator: "\n"),
            originalTargetDuration: original,
            correctedTargetDuration: corrected,
            maximumSegmentDuration: maximum
        )
    }

    private static func absoluteURI(_ value: String, baseURL: URL) throws -> String {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw HybridHLSManifestFallbackError.invalidResourceURI
        }
        return url.absoluteString
    }
}

enum HybridHLSManifestFallbackError: Error, LocalizedError {
    case unrepresentableDuration
    case invalidResourceURI
    case missingListenerPort
    case stopped

    var errorDescription: String? {
        switch self {
        case .unrepresentableDuration:
            "HLS target-duration fallback cannot represent the segment duration"
        case .invalidResourceURI:
            "HLS target-duration fallback cannot resolve a resource URL"
        case .missingListenerPort:
            "HLS target-duration fallback listener has no port"
        case .stopped:
            "HLS target-duration fallback was stopped"
        }
    }
}

/// Session-owned, loopback-only origin for the repaired manifest. It never
/// downloads, proxies, caches, or substitutes media segments.
final class HybridHLSManifestServer: @unchecked Sendable {
    private let listener: NWListener
    private let playlist: Data
    private let path = "/\(UUID().uuidString)/media.m3u8"
    private let queue = DispatchQueue(label: "com.qoli.syncnexthybrid.manifest-fallback")
    private let lock = NSLock()
    private var startup: CheckedContinuation<URL, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    private init(repair: HybridHLSManifestRepair) throws {
        playlist = Data(repair.playlist.utf8)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(
        repair: HybridHLSManifestRepair
    ) async throws -> (server: HybridHLSManifestServer, url: URL) {
        let server = try Self(repair: repair)
        let url: URL
        do {
            url = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    server.listen(continuation)
                }
            } onCancel: {
                server.stop()
            }
        } catch {
            server.stop()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        return (server, url)
    }

    private func listen(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        startup = continuation
        lock.unlock()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)") else {
                    self.finishStartup(.failure(HybridHLSManifestFallbackError.missingListenerPort))
                    return
                }
                self.finishStartup(.success(url))
            case .failed(let error):
                self.finishStartup(.failure(error))
                self.stop()
            case .cancelled:
                self.finishStartup(.failure(CancellationError()))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func finishStartup(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = startup
        startup = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: request)
            } else if complete || error != nil {
                self.close(connection)
            } else {
                self.receive(connection, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let firstLine = String(decoding: request, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline }).first ?? ""
        let fields = firstLine.split(separator: " ")
        let method = fields.first.map(String.init) ?? ""
        let matches = fields.count >= 2 && fields[1] == path
        let supported = method == "GET" || method == "HEAD"
        let status = !matches ? "404 Not Found" : (supported ? "200 OK" : "405 Method Not Allowed")
        let body = matches && supported ? playlist : Data()
        var response = Data((
            "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/vnd.apple.mpegurl\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        ).utf8)
        if method != "HEAD" { response.append(body) }
        if matches && supported {
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_MANIFEST_FALLBACK event=served method=\(method) bytes=\(body.count)"
            )
        }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let active = Array(connections.values)
        connections.removeAll()
        let continuation = startup
        startup = nil
        lock.unlock()
        continuation?.resume(throwing: HybridHLSManifestFallbackError.stopped)
        listener.cancel()
        active.forEach { $0.cancel() }
    }

    deinit { stop() }
}
