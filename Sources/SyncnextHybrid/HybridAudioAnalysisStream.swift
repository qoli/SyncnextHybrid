import Foundation

actor HybridAudioDemandGate {
    private enum State {
        case active
        case finished
        case failed(HybridAudioAnalysisError)
    }

    private var state: State = .active
    private var consumerID: UUID?
    private var consumerWaiter:
        CheckedContinuation<HybridAudioAnalysisBuffer?, Error>?
    private var producerWaiter: CheckedContinuation<Void, Error>?

    func waitForDemand() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await waitForDemandUncancelled()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func waitForDemandUncancelled() async throws {
        try assertActive()
        if consumerWaiter != nil {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            producerWaiter = continuation
        }
        try assertActive()
    }

    func next(consumerID: UUID) async throws -> HybridAudioAnalysisBuffer? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await nextUncancelled(consumerID: consumerID)
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func nextUncancelled(
        consumerID: UUID
    ) async throws -> HybridAudioAnalysisBuffer? {
        switch state {
        case .finished:
            return nil
        case .failed(let error):
            throw error
        case .active:
            break
        }
        if let bound = self.consumerID, bound != consumerID {
            throw HybridAudioAnalysisError.concurrentConsumer
        }
        self.consumerID = consumerID
        guard consumerWaiter == nil else {
            throw HybridAudioAnalysisError.concurrentConsumer
        }
        if let producerWaiter {
            self.producerWaiter = nil
            producerWaiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            consumerWaiter = continuation
        }
    }

    func yield(_ buffer: HybridAudioAnalysisBuffer) -> Bool {
        guard case .active = state, let consumerWaiter else {
            return false
        }
        self.consumerWaiter = nil
        consumerWaiter.resume(returning: buffer)
        return true
    }

    func finish() {
        guard case .active = state else {
            return
        }
        state = .finished
        consumerWaiter?.resume(returning: nil)
        consumerWaiter = nil
        producerWaiter?.resume(throwing: HybridAudioAnalysisError.cancelled)
        producerWaiter = nil
    }

    func fail(_ error: HybridAudioAnalysisError) {
        guard case .active = state else {
            return
        }
        state = .failed(error)
        consumerWaiter?.resume(throwing: error)
        consumerWaiter = nil
        producerWaiter?.resume(throwing: error)
        producerWaiter = nil
    }

    func cancel() {
        fail(.cancelled)
    }

    private func assertActive() throws {
        switch state {
        case .active:
            return
        case .finished:
            throw HybridAudioAnalysisError.cancelled
        case .failed(let error):
            throw error
        }
    }
}

public final class HybridAudioAnalysisStream:
    AsyncSequence,
    @unchecked Sendable
{
    public typealias Element = HybridAudioAnalysisBuffer

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let gate: HybridAudioDemandGate
        private let cancelImpl: @Sendable () -> Void
        private let consumerID = UUID()

        fileprivate init(
            gate: HybridAudioDemandGate,
            cancel: @escaping @Sendable () -> Void
        ) {
            self.gate = gate
            self.cancelImpl = cancel
        }

        public mutating func next() async throws -> Element? {
            do {
                return try await gate.next(consumerID: consumerID)
            } catch is CancellationError {
                cancelImpl()
                throw HybridAudioAnalysisError.cancelled
            } catch {
                if Task.isCancelled {
                    cancelImpl()
                }
                throw error
            }
        }
    }

    private let gate: HybridAudioDemandGate
    private let cancelImpl: @Sendable () -> Void

    init(
        gate: HybridAudioDemandGate,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.gate = gate
        self.cancelImpl = cancel
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(gate: gate, cancel: cancelImpl)
    }

    public func cancel() {
        cancelImpl()
    }
}
