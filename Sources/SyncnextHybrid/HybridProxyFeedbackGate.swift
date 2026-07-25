import Foundation

/// Keeps AVPlayer state mirrored by Hybrid from being interpreted as a new
/// AVKit transport command. In particular, AVPlayer emits `rate == 0` while a
/// mirrored seek is still in flight.
final class HybridProxyFeedbackGate: @unchecked Sendable {
    private static let maximumPendingObservations = 8
    private static let rateTolerance: Float = 0.0001

    private let lock = NSLock()
    private var pendingMirroredRates: [Float] = []
    private var activeMirroredSeekTokens: Set<UInt64> = []
    private var nextMirroredSeekToken: UInt64 = 0

    func performMirroredRateChange(
        to rate: Float,
        _ change: () -> Void
    ) {
        lock.lock()
        pendingMirroredRates.append(rate)
        trimPendingObservations(&pendingMirroredRates)
        lock.unlock()
        change()
    }

    func shouldForwardRateObservation(_ rate: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let index = pendingMirroredRates.firstIndex(
            where: {
                abs($0 - rate) <= Self.rateTolerance
            }
        ) {
            pendingMirroredRates.remove(at: index)
            return false
        }

        if abs(rate) <= Self.rateTolerance,
           !activeMirroredSeekTokens.isEmpty {
            return false
        }

        pendingMirroredRates.removeAll()
        return true
    }

    func beginMirroredSeek() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        nextMirroredSeekToken &+= 1
        activeMirroredSeekTokens.insert(nextMirroredSeekToken)
        return nextMirroredSeekToken
    }

    func completeMirroredSeek(_ token: UInt64) {
        lock.lock()
        activeMirroredSeekTokens.remove(token)
        lock.unlock()
    }

    private func trimPendingObservations<T>(
        _ observations: inout [T]
    ) {
        let overflow =
            observations.count - Self.maximumPendingObservations
        if overflow > 0 {
            observations.removeFirst(overflow)
        }
    }
}
