#if DEBUG
import AetherEngine
import Foundation

/// Launch-scoped experiments, never selected by ordinary playback or Release.
public enum HybridVODRangeTestMode: String, Sendable, CaseIterable {
    case single
    case dual

    public var requestCount: Int { self == .single ? 1 : 2 }

    func validate(admission: HybridRemoteSourceAdmission, url: URL) throws {
        guard admission == .aetherDefault(.confirmedNonHLS),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw HybridRangeTestReader.Failure.unsupportedSource
        }
    }
}

public struct HybridVODRangeTestObservation: Sendable {
    public let sourceBytes: Int64
    public let deliveredBytes: Int64
    public let requestsStarted: Int
    public let requestsCompleted: Int
    public let requestsCancelled: Int
    public let activeRequests: Int
    public let peakActiveRequests: Int
    /// Accepted HTTP response bodies, rather than merely enqueued tasks.
    public let peakActiveResponses: Int
    public let bufferedBytes: Int
    public let peakBufferedBytes: Int
    public let readWaitSeconds: Double
    public let networkActiveSeconds: Double
    public let protocols: [String]
    public let validator: String
    public let failure: String?
    public let independentReaders: Int
    public internal(set) var independentSourceBytes: Int64
    public let activity: HybridVODRangeActivityObservation
}

/// Finite HTTP file experiment using Aether's public IOReader seam. Both modes
/// have the same 4 MiB ranges and 16 MiB read-ahead window; only the number of
/// concurrent tasks differs. Bytes become readable as they arrive, not when a
/// whole range finishes. No retries, URL fallback, or recovery policy lives here.
final class HybridRangeTestReader: IOReader, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case unsupportedSource, cancelled, invalidResponse, invalidRange
        case missingStrongValidator, identityChanged, encodedResponse, shortBody
        case httpStatus(Int)
        case transport(String, Int)
    }

    private struct Identity {
        let size: Int64
        let etag: String?
        let field: String
        let value: String
    }

    private final class Block {
        let lower: Int64
        let upper: Int64 // exclusive
        var data = Data()
        var complete = false
        init(lower: Int64, upper: Int64) { self.lower = lower; self.upper = upper }
    }

    private final class Transfer {
        let task: URLSessionDataTask
        let block: Block
        let metadata: Bool
        var acceptedResponse = false
        var identity: Identity?
        init(task: URLSessionDataTask, block: Block, metadata: Bool) {
            self.task = task; self.block = block; self.metadata = metadata
        }
    }

    static let rangeBytes: Int64 = 4 * 1024 * 1024
    private static let windowBlocks = 4 // same 16 MiB high water as the current source reader
    private let condition = NSCondition()
    private let url: URL
    private let headers: [String: String]
    private let mode: HybridVODRangeTestMode
    private let configuration: URLSessionConfiguration
    private let delegate: RangeDelegate
    private let session: URLSession
    private var identity: Identity?
    private var position: Int64 = 0
    private var frontier: Int64 = 0
    private var blocks: [Block] = []
    private var transfers: [Int: Transfer] = [:]
    private var cancelled = false
    private var closed = false
    private var failure: Failure?
    private var lastFailure: Failure?
    private var children: [HybridRangeTestReader] = []
    private var sourceBytes: Int64 = 0
    private var deliveredBytes: Int64 = 0
    private var requestsStarted = 0
    private var requestsCompleted = 0
    private var requestsCancelled = 0
    private var peakActiveRequests = 0
    private var activeResponses = 0
    private var peakActiveResponses = 0
    private var peakBufferedBytes = 0
    private var readWaitSeconds = 0.0
    private var networkActiveSeconds = 0.0
    private var activeSince: Double?
    private var protocols: Set<String> = []
    private var telemetry: HybridVODRangeTestTelemetry

    var discImageProbeEnabled: Bool { false }

    private init(
        url: URL, headers: [String: String], mode: HybridVODRangeTestMode,
        configuration: URLSessionConfiguration, identity: Identity? = nil, role: String = "primary"
    ) {
        self.url = url
        self.headers = headers
        self.mode = mode
        self.identity = identity
        telemetry = HybridVODRangeTestTelemetry(role: role)
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 35 // current AVIOReader request timeout
        config.httpMaximumConnectionsPerHost = mode.requestCount
        self.configuration = config
        delegate = RangeDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        delegate.owner = self
    }

    static func open(
        url: URL, headers: [String: String], mode: HybridVODRangeTestMode,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> HybridRangeTestReader {
        let reader = HybridRangeTestReader(url: url, headers: headers, mode: mode, configuration: configuration)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await Task.detached { try reader.prepareMetadata() }.value
                try Task.checkCancellation()
            } onCancel: { reader.cancel() }
            return reader
        } catch {
            reader.close()
            // Session preparation can fail before the Probe owns this reader.
            // Preserve the failed metadata request with the same sanitized trace
            // schema, rather than losing its status, transport cause and metrics.
            for batch in reader.drainTrace() {
                if let data = try? JSONEncoder().encode(batch), let text = String(data: data, encoding: .utf8) {
                    print("VOD_RANGE_TRACE \(text)")
                }
            }
            throw error
        }
    }

    private func prepareMetadata() throws {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled, !closed else { throw Failure.cancelled }
        startLocked(Block(lower: 0, upper: 1), metadata: true)
        while identity == nil, failure == nil, !cancelled, !closed { condition.wait() }
        if let failure { throw failure }
        guard !cancelled, !closed else { throw Failure.cancelled }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        condition.lock()
        defer { condition.unlock() }
        while true {
            guard !closed, !cancelled, failure == nil, let identity else { return -1 }
            guard position < identity.size else { return 0 }
            fillLocked()
            if let block = blocks.first(where: { $0.lower <= position && position < $0.upper }) {
                let offset = Int(position - block.lower)
                let available = block.data.count - offset
                if available > 0 {
                    let count = min(Int(size), available)
                    block.data.copyBytes(to: buffer, from: offset..<(offset + count))
                    position += Int64(count)
                    deliveredBytes += Int64(count)
                    fillLocked()
                    return Int32(count)
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            condition.wait()
            readWaitSeconds += ProcessInfo.processInfo.systemUptime - started
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, let identity else { return -1 }
        let direction = whence & ~Int32(0x20000) // AVSEEK_FORCE
        if direction == 65536 { return identity.size }
        let base: Int64
        switch direction {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: base = identity.size
        default: return -1
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0, target <= identity.size else { return -1 }
        // A bridge reopen seeks the retained reader. Cancellation unblocks a
        // previous read, while this explicit reposition starts the new epoch.
        let resident = blocks.contains { $0.lower <= target && target < $0.upper }
        if cancelled || !resident {
            cancelTransfersLocked(reason: "seek")
            telemetry.nextEpoch()
            blocks.removeAll()
            frontier = target
            failure = nil
        }
        cancelled = false
        // Only an explicit caller reposition/reopen starts another epoch. The
        // reader never retries on its own; the engine keeps owning recovery.
        position = target
        condition.broadcast()
        return target
    }

    func cancel() {
        condition.lock()
        cancelled = true
        cancelTransfersLocked(reason: "cancel")
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        cancelTransfersLocked(reason: "close")
        blocks.removeAll()
        let children = children
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
        for child in children { child.close() }
    }

    func makeIndependentReader() -> IOReader? {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !cancelled, failure == nil, let identity else { return nil }
        // Side readers preserve existing subtitle/scrub capabilities, with their
        // own cursor. Meter them separately so they cannot fake primary parallelism.
        let child = HybridRangeTestReader(
            url: url, headers: headers, mode: .single, configuration: configuration, identity: identity,
            role: "independent"
        )
        children.append(child)
        return child
    }

    var observation: HybridVODRangeTestObservation {
        condition.lock()
        let children = children
        var snapshot = HybridVODRangeTestObservation(
            sourceBytes: sourceBytes, deliveredBytes: deliveredBytes,
            requestsStarted: requestsStarted, requestsCompleted: requestsCompleted,
            requestsCancelled: requestsCancelled, activeRequests: transfers.count,
            peakActiveRequests: peakActiveRequests, peakActiveResponses: peakActiveResponses,
            bufferedBytes: bufferedBytesLocked, peakBufferedBytes: peakBufferedBytes,
            readWaitSeconds: readWaitSeconds,
            networkActiveSeconds: networkActiveSeconds + (activeSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0),
            protocols: protocols.sorted(), validator: identity?.field ?? "unavailable",
            failure: lastFailure.map { String(describing: $0) },
            independentReaders: children.count, independentSourceBytes: 0,
            activity: telemetry.activity(at: ProcessInfo.processInfo.systemUptime)
        )
        condition.unlock()
        snapshot.independentSourceBytes = children.reduce(0) { $0 + $1.observation.sourceBytes }
        return snapshot
    }

    func drainTrace() -> [HybridVODRangeTraceBatch] {
        condition.lock()
        let batch = telemetry.drain(at: ProcessInfo.processInfo.systemUptime)
        let children = children
        condition.unlock()
        return (batch.map { [$0] } ?? []) + children.flatMap { $0.drainTrace() }
    }

    private var bufferedBytesLocked: Int { blocks.reduce(0) { $0 + $1.data.count } }

    private func fillLocked() {
        guard !closed, !cancelled, failure == nil, let identity else { return }
        blocks.removeAll { $0.complete && $0.upper <= position }
        while transfers.count < mode.requestCount, blocks.count < Self.windowBlocks, frontier < identity.size {
            let upper = frontier + min(Self.rangeBytes, identity.size - frontier)
            let block = Block(lower: frontier, upper: upper)
            blocks.append(block)
            frontier = upper
            startLocked(block, metadata: false)
        }
    }

    private func startLocked(_ block: Block, metadata: Bool) {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.setValue("bytes=\(block.lower)-\(block.upper - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let identity { request.setValue(identity.value, forHTTPHeaderField: "If-Range") }
        let task = session.dataTask(with: request)
        if transfers.isEmpty { activeSince = ProcessInfo.processInfo.systemUptime }
        transfers[task.taskIdentifier] = Transfer(task: task, block: block, metadata: metadata)
        telemetry.start(
            id: task.taskIdentifier, metadata: metadata, lower: block.lower, upper: block.upper,
            blocks: blocks.count, buffered: bufferedBytesLocked, at: ProcessInfo.processInfo.systemUptime
        )
        requestsStarted += 1
        peakActiveRequests = max(peakActiveRequests, transfers.count)
        task.resume()
    }

    private func finishActivityLocked() {
        if transfers.isEmpty, let started = activeSince {
            networkActiveSeconds += ProcessInfo.processInfo.systemUptime - started
            activeSince = nil
        }
    }

    private func cancelTransfersLocked(reason: String) {
        let active = transfers.values.map(\.task)
        for task in active {
            telemetry.finish(id: task.taskIdentifier, outcome: "cancelled", reason: reason, at: ProcessInfo.processInfo.systemUptime)
        }
        requestsCancelled += active.count
        transfers.removeAll()
        activeResponses = 0
        finishActivityLocked()
        for task in active { task.cancel() }
    }

    private func failLocked(_ error: Failure) {
        if failure == nil { failure = error }
        lastFailure = error
        cancelTransfersLocked(reason: "source-failure")
        condition.broadcast()
    }

    private func receive(_ response: URLResponse, task: URLSessionDataTask) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let transfer = transfers[task.taskIdentifier] else { return false }
        telemetry.headers(id: task.taskIdentifier, status: (response as? HTTPURLResponse)?.statusCode,
                          accepted: false, at: ProcessInfo.processInfo.systemUptime)
        do {
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            guard http.statusCode == 206 else { throw Failure.httpStatus(http.statusCode) }
            guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                throw Failure.encodedResponse
            }
            let parts = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: " ")
            guard let parts, parts.count == 2, parts[0].lowercased() == "bytes" else { throw Failure.invalidRange }
            let sizes = parts[1].split(separator: "/")
            let ends = sizes.first?.split(separator: "-") ?? []
            guard sizes.count == 2, ends.count == 2,
                  let lower = Int64(ends[0]), let last = Int64(ends[1]), let total = Int64(sizes[1]),
                  total > last, lower == transfer.block.lower, last == transfer.block.upper - 1 else {
                throw Failure.invalidRange
            }
            let etag = http.value(forHTTPHeaderField: "ETag")
            let responseIdentity: Identity
            if let identity {
                guard identity.size == total, identity.etag == etag,
                      http.value(forHTTPHeaderField: identity.field) == identity.value else {
                    throw Failure.identityChanged
                }
                responseIdentity = identity
            } else if let etag, Self.isStrongETag(etag) {
                responseIdentity = Identity(size: total, etag: etag, field: "ETag", value: etag)
            } else {
                // RFC 9110 §§8.8.2.2/13.1.5 permits a strong HTTP-date when no
                // entity-tag is available. An unquoted provider hash is not an
                // entity-tag; retain it as additional identity evidence anyway.
                guard etag?.hasPrefix("W/") != true,
                      let modified = http.value(forHTTPHeaderField: "Last-Modified"),
                      let date = http.value(forHTTPHeaderField: "Date"),
                      let modifiedAt = Self.httpDate(modified), let sentAt = Self.httpDate(date),
                      sentAt.timeIntervalSince(modifiedAt) >= 1 else { throw Failure.missingStrongValidator }
                responseIdentity = Identity(size: total, etag: etag, field: "Last-Modified", value: modified)
            }
            if let length = http.value(forHTTPHeaderField: "Content-Length"), Int64(length) != transfer.block.upper - lower {
                throw Failure.shortBody
            }
            transfer.identity = responseIdentity
            transfer.acceptedResponse = true
            activeResponses += 1
            peakActiveResponses = max(peakActiveResponses, activeResponses)
            telemetry.headers(id: task.taskIdentifier, status: http.statusCode, accepted: true,
                              at: ProcessInfo.processInfo.systemUptime)
            return true
        } catch {
            telemetry.finish(id: task.taskIdentifier, outcome: "failed", reason: String(describing: error),
                             at: ProcessInfo.processInfo.systemUptime)
            failLocked(error as? Failure ?? .invalidResponse)
            return false
        }
    }

    private static func isStrongETag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count >= 2 && bytes.first == 0x22 && bytes.last == 0x22
            && bytes.dropFirst().dropLast().allSatisfy { $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value)
    }

    private func receive(_ data: Data, task: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        // Count even late cancelled bytes, but never put them in the new window.
        sourceBytes += Int64(data.count)
        telemetry.data(id: task.taskIdentifier, bytes: data.count, at: ProcessInfo.processInfo.systemUptime)
        guard let transfer = transfers[task.taskIdentifier], transfer.acceptedResponse else { return }
        guard Int64(transfer.block.data.count) + Int64(data.count) <= transfer.block.upper - transfer.block.lower else {
            failLocked(.shortBody)
            return
        }
        transfer.block.data.append(data)
        peakBufferedBytes = max(peakBufferedBytes, bufferedBytesLocked)
        condition.broadcast()
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        if transfer.acceptedResponse { activeResponses -= 1 }
        finishActivityLocked()
        if let error {
            let ns = error as NSError
            telemetry.finish(id: task.taskIdentifier, outcome: "failed", reason: "\(ns.domain)/\(ns.code)",
                             at: ProcessInfo.processInfo.systemUptime)
            failLocked(.transport(ns.domain, ns.code))
        } else if !transfer.acceptedResponse || Int64(transfer.block.data.count) != transfer.block.upper - transfer.block.lower {
            telemetry.finish(id: task.taskIdentifier, outcome: "failed", reason: "short-body",
                             at: ProcessInfo.processInfo.systemUptime)
            failLocked(.shortBody)
        } else {
            telemetry.finish(id: task.taskIdentifier, outcome: "completed", at: ProcessInfo.processInfo.systemUptime)
            requestsCompleted += 1
            transfer.block.complete = true
            if transfer.metadata { identity = transfer.identity }
            // Metadata completion only establishes identity. Actual read demand
            // starts the window so startup probes cannot download an idle file.
            if !transfer.metadata { fillLocked() }
            condition.broadcast()
        }
    }

    private func collect(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
        condition.lock()
        telemetry.metrics(id: task.taskIdentifier, transactions: metrics.transactionMetrics)
        for transaction in metrics.transactionMetrics {
            if let name = transaction.networkProtocolName { protocols.insert(name) }
        }
        condition.unlock()
    }

    private final class RangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: HybridRangeTestReader?
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(owner?.receive(response, task: dataTask) == true ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.receive(data, task: dataTask)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.complete(task, error: error)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            owner?.collect(metrics, task: task)
        }
    }
}
#endif
