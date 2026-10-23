import Darwin
import Foundation

/// Process-wide CPU is an upper bound on probe computation, not demux-thread CPU.
struct ProbeCPUUsage: Sendable {
    let user: Double
    let system: Double

    static func read() -> Self? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return .init(
            user: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
            system: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        )
    }
}

/// The public SDK sink must not block the demux thread on private-file writes.
final class ProbeEngineLog: @unchecked Sendable {
    private struct Line: Encodable, Sendable {
        let uptime_seconds: Double
        let epoch_seconds: Double
        let thread_id: UInt64
        let message: String
        let process_cpu_user_seconds: Double?
        let process_cpu_system_seconds: Double?
    }

    private let queue = DispatchQueue(label: "com.qoli.MacStartupProbe.engine-log")
    private let file: FileHandle
    private var isClosed = false

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("engine-events.private.jsonl")
        guard !FileManager.default.fileExists(atPath: path.path), FileManager.default.createFile(
            atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteFileExists) }
        file = try FileHandle(forWritingTo: path)
    }

    func append(_ message: String) {
        var thread: UInt64 = 0
        pthread_threadid_np(nil, &thread)
        let cpu = message.contains("avformat_find_stream_info") || message.contains("Probe buffer size limit")
            ? ProbeCPUUsage.read() : nil
        let line = Line(
            uptime_seconds: ProcessInfo.processInfo.systemUptime,
            epoch_seconds: Date().timeIntervalSince1970,
            thread_id: thread, message: message,
            process_cpu_user_seconds: cpu?.user, process_cpu_system_seconds: cpu?.system
        )
        queue.async {
            guard !self.isClosed else { return }
            do {
                var data = try JSONEncoder().encode(line)
                data.append(0x0A)
                try self.file.write(contentsOf: data)
            } catch {
                FileHandle.standardError.write(Data("MAC_STARTUP_PROBE engine-log-write-failed\n".utf8))
            }
        }
    }

    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            try? file.close()
        }
    }
}
