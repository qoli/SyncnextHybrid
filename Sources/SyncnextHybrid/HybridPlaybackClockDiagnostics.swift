import AetherEngine
import Foundation

enum HybridPlaybackClockDiagnostics {
    static func number(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        guard value.isFinite else { return String(describing: value) }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func ageMilliseconds(since instant: TimeInterval?, now: TimeInterval) -> String {
        number(instant.map { (now - $0) * 1_000 })
    }

    static func identity(_ object: AnyObject?) -> String {
        object.map { String(ObjectIdentifier($0).hashValue, radix: 16) } ?? "none"
    }

    static func phase(_ value: HybridPlaybackPhase) -> String {
        switch value {
        case .idle: "idle"
        case .loading: "loading"
        case .waitingToPlay: "waitingToPlay"
        case .playing: "playing"
        case .paused: "paused"
        case .seeking: "seeking"
        case .rebuffering: "rebuffering"
        case .stalled: "stalled"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}

/// Audio selection creates an SDK child Task. Its inherited context joins the
/// existing rebuild logs to the requesting Hybrid session without SDK changes.
enum HybridAudioReloadDiagnostics {
    struct Context: Sendable {
        let session: String
        let operation: String
    }
    @TaskLocal static var context: Context?

    private static let bridge: Void = {
        let previous = EngineLog.handler
        EngineLog.handler = { message in
            previous?(message)
            guard let context, let fields = safeFields(message) else { return }
            HybridDiagnosticEmitter.emit(
                "ENGINE_REBUILD \(fields) session=\(context.session) originOperation=\(context.operation)"
                    + " uptimeMs=\(Int64(ProcessInfo.processInfo.systemUptime * 1_000))"
            )
        }
    }()

    static func install() { _ = bridge }

    /// Retain only known events and numeric fields. SDK failures and subtitle
    /// names can contain private paths or signed URLs, so never forward prose.
    static func safeFields(_ message: String) -> String? {
        func numeric(_ key: String, suffix: Character? = nil) -> String {
            guard let token = message.split(separator: " ").first(where: { $0.hasPrefix(key + "=") }) else {
                return "unavailable"
            }
            var value = token.dropFirst(key.count + 1)
            if let suffix, value.last == suffix { value = value.dropLast() }
            return HybridPlaybackClockDiagnostics.number(Double(value))
        }
        if message.hasPrefix("[AetherEngine] reload begin:") {
            return "event=begin audioStream=\(numeric("audioStream")) resumeAt=\(numeric("resumeAt", suffix: "s"))"
        }
        if message.hasPrefix("[AetherEngine] reload: stopInternal start") { return "event=stop-start" }
        if message.hasPrefix("[AetherEngine] reload: stopInternal done") { return "event=stop-done" }
        if message.hasPrefix("[AetherEngine] reload: loadNative enter") {
            return "event=load-enter backend=native audioStream=\(numeric("audio")) resumeAt=\(numeric("resumeAt", suffix: "s"))"
        }
        if message.hasPrefix("[AetherEngine] reload: loadSoftware enter") {
            return "event=load-enter backend=software audioStream=\(numeric("audio")) resumeAt=\(numeric("resumeAt", suffix: "s"))"
        }
        if message.hasPrefix("[AetherEngine] reload: state=.playing") { return "event=completed state=playing" }
        if message.hasPrefix("[AetherEngine] reload: state=.paused") { return "event=completed state=paused" }
        if message.hasPrefix("[AetherEngine] selectAudioTrack reload failed:") { return "event=failed" }
        if message.hasPrefix("[AetherEngine] reload superseded") { return "event=superseded" }
        return nil
    }
}
