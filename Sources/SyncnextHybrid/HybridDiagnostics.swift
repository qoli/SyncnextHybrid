import Foundation

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
