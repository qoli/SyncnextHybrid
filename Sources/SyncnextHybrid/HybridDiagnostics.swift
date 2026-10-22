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
