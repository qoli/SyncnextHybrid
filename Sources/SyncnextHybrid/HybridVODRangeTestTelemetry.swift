#if DEBUG
import Foundation

public struct HybridVODRangeTransactionTrace: Codable, Sendable {
    public let schedulingSeconds: Double?
    public let setupSeconds: Double?
    public let dnsSeconds: Double?
    public let connectSeconds: Double?
    public let tlsSeconds: Double?
    public let requestSendSeconds: Double?
    public let responseWaitSeconds: Double?
    public let responseBodySeconds: Double?
    public let protocolName: String?
    public let reusedConnection: Bool
    public let proxyConnection: Bool
    public let remoteAddress: String?
    public let resourceFetchType: Int
    public let receivedBodyBytes: Int64

    init(_ metrics: URLSessionTaskTransactionMetrics, queuedAt: Date) {
        schedulingSeconds = Self.interval(queuedAt, metrics.fetchStartDate)
        setupSeconds = Self.interval(metrics.fetchStartDate, metrics.requestStartDate)
        dnsSeconds = Self.interval(metrics.domainLookupStartDate, metrics.domainLookupEndDate)
        connectSeconds = Self.interval(metrics.connectStartDate, metrics.connectEndDate)
        tlsSeconds = Self.interval(metrics.secureConnectionStartDate, metrics.secureConnectionEndDate)
        requestSendSeconds = Self.interval(metrics.requestStartDate, metrics.requestEndDate)
        responseWaitSeconds = Self.interval(metrics.requestEndDate, metrics.responseStartDate)
        responseBodySeconds = Self.interval(metrics.responseStartDate, metrics.responseEndDate)
        protocolName = metrics.networkProtocolName
        reusedConnection = metrics.isReusedConnection
        proxyConnection = metrics.isProxyConnection
        remoteAddress = metrics.remoteAddress
        resourceFetchType = metrics.resourceFetchType.rawValue
        receivedBodyBytes = metrics.countOfResponseBodyBytesReceived
    }

    private static func interval(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end else { return nil }
        let value = end.timeIntervalSince(start)
        return value >= 0 ? value : nil
    }
}

public struct HybridVODRangeRequestTrace: Codable, Sendable {
    public let taskID: Int
    public let epoch: Int
    public let metadata: Bool
    public let lower: Int64
    public let upperExclusive: Int64
    public let queuedAt: Double
    public let windowBlocksAtStart: Int
    public let bufferedBytesAtStart: Int
    public var headersAt: Double?
    public var firstBodyAt: Double?
    public var lastBodyAt: Double?
    public var finishedAt: Double?
    public var status: Int?
    public var bytes: Int64 = 0
    public var lateBytes: Int64 = 0
    public var maximumBodyGapSeconds: Double = 0
    public var outcome = "open"
    public var cancellationReason: String?
    /// nil means the metrics callback has not arrived; [] means it arrived
    /// without transactions. No URL, headers, cookies or validators are copied.
    public var transactions: [HybridVODRangeTransactionTrace]?
}

public struct HybridVODRangeActivitySpan: Codable, Sendable {
    public let start: Double
    public var end: Double
    public let tasks: Int
    public let responses: Int
}

public struct HybridVODRangeTraceBatch: Codable, Sendable {
    public let schema: Int
    public let readerID: String
    public let role: String
    public let requests: [HybridVODRangeRequestTrace]
    public let activity: [HybridVODRangeActivitySpan]
}

/// Owned under the reader's condition lock. Records observation only; it never
/// schedules, delays, retries or cancels network work. Records are coalesced and
/// drained at the existing Probe tick, including late metrics after seek/cancel.
public struct HybridVODRangeActivityObservation: Sendable {
    public let at: Double
    public let singleTaskSeconds: Double
    public let dualTaskSeconds: Double
    public let singleResponseSeconds: Double
    public let dualResponseSeconds: Double
}

struct HybridVODRangeTestTelemetry {

    private let readerID = String(UUID().uuidString.prefix(8))
    private let role: String
    private let origin: Double
    private var epoch = 0
    private var records: [Int: HybridVODRangeRequestTrace] = [:]
    private var queuedDates: [Int: Date] = [:]
    private var dirty: Set<Int> = []
    private var tasks: Set<Int> = []
    private var responses: Set<Int> = []
    private var spans: [HybridVODRangeActivitySpan] = []
    private var lastAt = 0.0
    private var taskSeconds: [Int: Double] = [:]
    private var responseSeconds: [Int: Double] = [:]

    init(role: String, origin: Double = ProcessInfo.processInfo.systemUptime) {
        self.role = role
        self.origin = origin
    }

    mutating func nextEpoch() { epoch += 1 }

    mutating func start(
        id: Int, metadata: Bool, lower: Int64, upper: Int64,
        blocks: Int, buffered: Int, at now: Double, date: Date = Date()
    ) {
        advance(to: now)
        records[id] = HybridVODRangeRequestTrace(
            taskID: id, epoch: epoch, metadata: metadata, lower: lower, upperExclusive: upper,
            queuedAt: now - origin, windowBlocksAtStart: blocks, bufferedBytesAtStart: buffered
        )
        queuedDates[id] = date
        tasks.insert(id)
        dirty.insert(id)
    }

    mutating func headers(id: Int, status: Int?, accepted: Bool, at now: Double) {
        guard var record = records[id], record.finishedAt == nil else { return }
        advance(to: now)
        record.headersAt = now - origin
        record.status = status
        records[id] = record
        if accepted { responses.insert(id) }
        dirty.insert(id)
    }

    mutating func data(id: Int, bytes: Int, at now: Double) {
        guard var record = records[id] else { return }
        if record.finishedAt != nil {
            record.lateBytes += Int64(bytes)
        } else {
            let at = now - origin
            if let previous = record.lastBodyAt {
                record.maximumBodyGapSeconds = max(record.maximumBodyGapSeconds, at - previous)
            }
            if record.firstBodyAt == nil { record.firstBodyAt = at }
            record.lastBodyAt = at
            record.bytes += Int64(bytes)
        }
        records[id] = record
        dirty.insert(id)
    }

    mutating func finish(id: Int, outcome: String, reason: String? = nil, at now: Double) {
        guard var record = records[id], record.finishedAt == nil else { return }
        advance(to: now)
        tasks.remove(id)
        responses.remove(id)
        record.finishedAt = now - origin
        record.outcome = outcome
        record.cancellationReason = reason
        records[id] = record
        dirty.insert(id)
    }

    mutating func metrics(id: Int, transactions: [URLSessionTaskTransactionMetrics]) {
        guard var record = records[id], let queuedAt = queuedDates[id] else { return }
        record.transactions = transactions.map { HybridVODRangeTransactionTrace($0, queuedAt: queuedAt) }
        records[id] = record
        dirty.insert(id)
    }

    func activity(at now: Double) -> HybridVODRangeActivityObservation {
        let pending = now - origin - lastAt
        return HybridVODRangeActivityObservation(
            at: now - origin,
            singleTaskSeconds: taskSeconds[1, default: 0] + (tasks.count == 1 ? pending : 0),
            dualTaskSeconds: taskSeconds[2, default: 0] + (tasks.count == 2 ? pending : 0),
            singleResponseSeconds: responseSeconds[1, default: 0] + (responses.count == 1 ? pending : 0),
            dualResponseSeconds: responseSeconds[2, default: 0] + (responses.count == 2 ? pending : 0)
        )
    }

    mutating func drain(at now: Double) -> HybridVODRangeTraceBatch? {
        advance(to: now)
        guard !dirty.isEmpty || !spans.isEmpty else { return nil }
        let batch = HybridVODRangeTraceBatch(
            schema: 2, readerID: readerID, role: role,
            requests: dirty.sorted().compactMap { records[$0] }, activity: spans
        )
        dirty.removeAll(keepingCapacity: true)
        spans.removeAll(keepingCapacity: true)
        return batch
    }

    private mutating func advance(to now: Double) {
        let at = now - origin
        guard at > lastAt else { return }
        let elapsed = at - lastAt
        taskSeconds[tasks.count, default: 0] += elapsed
        responseSeconds[responses.count, default: 0] += elapsed
        if let last = spans.last, last.tasks == tasks.count, last.responses == responses.count {
            spans[spans.count - 1].end = at
        } else {
            spans.append(HybridVODRangeActivitySpan(start: lastAt, end: at, tasks: tasks.count, responses: responses.count))
        }
        lastAt = at
    }
}
#endif
