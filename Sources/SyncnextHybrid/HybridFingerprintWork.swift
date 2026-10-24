import AetherEngine
import Foundation

/// Keep utility work off the actor while preserving its caller's cancellation.
enum HybridFingerprintWork {
    static func run<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try await operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Cancellation can arrive during a blocking demux read or while HLS prepares
/// its cursor. Closing the owned reader wakes that read and cancels its HTTP
/// producer; closing the demuxer releases only this analysis operation's input.
final class HybridAudioSourceCancellation: @unchecked Sendable {
    let demuxer = Demuxer()
    private let lock = NSLock()
    private var reader: (any IOReader)?
    private var openCompleted = false
    private var cancelled = false
    private var closed = false

    func register(reader: any IOReader) {
        lock.lock()
        let wasClosed = closed || cancelled
        if !wasClosed { self.reader = reader }
        lock.unlock()
        if wasClosed { reader.close() }
    }

    func didOpen() {
        lock.lock()
        openCompleted = true
        let closeDemuxer = cancelled && !closed
        if closeDemuxer { closed = true }
        lock.unlock()
        if closeDemuxer { demuxer.close() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let reader = reader
        let closeDemuxer = openCompleted && !closed
        if closeDemuxer { closed = true }
        lock.unlock()
        // Demuxer.openIndependent is not serialized against close(). During
        // open, cancel the owned reader and let the open call unwind first.
        reader?.close()
        if closeDemuxer { demuxer.close() }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let reader = reader
        self.reader = nil
        lock.unlock()
        reader?.close()
        demuxer.close()
    }
}
