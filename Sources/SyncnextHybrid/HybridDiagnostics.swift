import Foundation
import AetherEngine

/// A host can opt into metrics for Hybrid-owned source admission requests.
/// Ordinary playback installs no observer or additional admission delegate.
public enum HybridNetworkDiagnostics {
    private static let mediaRequestLogBridge: Void = {
        MediaRequestDiagnostics.handler = { line in
            HybridDiagnosticEmitter.emit(line)
        }
    }()

    static func installMediaRequestLogging() {
        _ = mediaRequestLogBridge
    }

    nonisolated(unsafe) public static var transactionMetricsObserver:
        (@Sendable (URLSessionTaskMetrics, String) -> Void)?

    static var sessionDelegate: URLSessionTaskDelegate? {
        transactionMetricsObserver == nil ? nil : metricsDelegate
    }

    private static let metricsDelegate = MetricsDelegate()

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            HybridNetworkDiagnostics.transactionMetricsObserver?(metrics, "source-admission")
        }
    }
}

#if DEBUG
public enum HybridMemoryDiagnostics {
    /// Opt-in for the memory acceptance case. Uses the SDK's existing pipeline
    /// probes and allocation census without owning a playback session.
    @MainActor
    public final class Observation {
        private let previous: ((String) -> Void)?

        public init(receive: @escaping @Sendable (String) -> Void) {
            previous = EngineLog.handler
            let previous = previous
            EngineLog.handler = { message in
                previous?(message)
                guard !message.contains("http://"), !message.contains("https://") else { return }
                if message.contains("memprobe") || message.contains("census") || message.contains("Census") {
                    receive(message)
                }
            }
            AetherEngine.setLargeAllocationCensusEnabled(true, triggerCaptureCap: 0)
        }

        public func stop() {
            AetherEngine.setLargeAllocationCensusEnabled(false)
            EngineLog.handler = previous
        }
    }
}
#endif

public extension Notification.Name {
    static let syncnextHybridDiagnostic = Notification.Name(
        "com.qoli.SyncnextHybrid.diagnostic"
    )
}

public enum HybridDiagnosticNotification {
    public static let messageKey = "message"
}

enum HybridDiagnosticEmitter {
    static func emit(_ message: String) {
        print(message)
        NotificationCenter.default.post(
            name: .syncnextHybridDiagnostic,
            object: nil,
            userInfo: [
                HybridDiagnosticNotification.messageKey: message,
            ]
        )
    }
}
