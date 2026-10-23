#if DEBUG
import AetherEngine
import Foundation

/// Launch-scoped observation of existing SDK boundaries. No transport commands
/// or SDK configuration are changed; ordinary playback installs no handler.
@MainActor
public final class HybridSeekDiagnosticObservation {
    private let previous: ((String) -> Void)?
    private let sink = SeekLogSink()
    private var stopped = false

    public init() {
        previous = EngineLog.handler
        let previous = previous
        let sink = sink
        EngineLog.handler = { message in
            previous?(message)
            sink.append(message)
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        EngineLog.handler = previous
        sink.close()
    }

    nonisolated static func safeMessage(_ message: String) -> String? {
        if message.hasPrefix("[NativeAVPlayerHost]"), message.contains("errorLog code=") {
            let tokens = message.split(separator: " ")
            guard let code = tokens.first(where: { $0.hasPrefix("code=") })
                .flatMap({ Int($0.dropFirst(5)) }) else { return nil }
            // Loader diagnostics may carry a media URI. Retain the numeric
            // error witness only, never the URI or arbitrary error text.
            return "[NativeAVPlayerHost] errorLog code=\(code)"
        }
        guard !message.contains("http://"), !message.contains("https://") else { return nil }
        if message.hasPrefix("[NativeAVPlayerHost]"),
           message.contains("timeControlStatus=") || message.contains("seek completion") {
            return message
        }
        if message.hasPrefix("[HLSVideoEngine]"),
           message.contains("producer restarted") || message.contains("declareTarget")
            || message.contains("serving while it is written") || message.contains("out-of-range fetch") {
            return message
        }
        if message.hasPrefix("[HLSSegmentProducer] video gate open")
            || message.hasPrefix("[HLSSegmentProducer] audio gate open")
            || message.hasPrefix("[AetherEngine] seek did not land within budget") {
            return message
        }
        return nil
    }
}

private final class SeekLogSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.qoli.SyncnextHybrid.seek-observation")
    private var closed = false

    func append(_ message: String) {
        guard let safe = HybridSeekDiagnosticObservation.safeMessage(message) else { return }
        // Stamp on the SDK emitter, before the asynchronous log handoff.
        let at = ProcessInfo.processInfo.systemUptime
        queue.async {
            guard !self.closed,
                  let data = try? JSONSerialization.data(withJSONObject: [
                    "uptime_seconds": at, "message": safe
                  ], options: [.sortedKeys]) else { return }
            var line = Data("SYNCNEXT_HYBRID_SEEK_TRACE ".utf8)
            line.append(data)
            line.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: line)
        }
    }

    func close() {
        queue.sync { closed = true }
    }
}
#endif
