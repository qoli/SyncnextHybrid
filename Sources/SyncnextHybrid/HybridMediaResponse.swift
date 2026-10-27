import CryptoKit
import Foundation

/// HTTP evidence from an existing media transfer. Observing this never opens a
/// connection. Source/resource identifiers are hashes, not replayable URLs.
public struct HybridMediaResponse: Sendable, Equatable {
    public let sourceID: String
    public let resourceID: String
    public let status: Int

    public static func sourceID(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Adapter for the exact-pinned MediaRequestDiagnostics wire format. Keep
    /// this boundary here instead of making App recovery interpret log prose.
    init?(diagnosticLine: String) {
        let tokens = diagnosticLine.split(separator: " ")
        guard tokens.first == "MEDIA_REQUEST" else { return nil }
        var fields: [Substring: Substring] = [:]
        for token in tokens.dropFirst() {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[pair[0]] = pair[1]
        }
        guard fields["event"] == "response",
              let sourceID = fields["sourceID"],
              let resourceID = fields["resourceID"],
              Self.isSourceID(sourceID), Self.isSourceID(resourceID),
              let rawStatus = fields["status"], let status = Int(rawStatus),
              (100...599).contains(status) else { return nil }
        self.sourceID = String(sourceID)
        self.resourceID = String(resourceID)
        self.status = status
    }

    private static func isSourceID(_ value: Substring) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
