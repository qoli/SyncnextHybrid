#if os(tvOS)
import AetherEngine
import Combine
import Foundation

/// Mirrors completed engine work, including its presenting witness. It does
/// not infer a first frame from AVPlayer's playing state or move transport.
@MainActor
final class HybridStartupDiagnostics {
    private let sessionID: String
    private let recordsStartup: Bool
    private let started = ProcessInfo.processInfo.systemUptime
    private var observation: AnyCancellable?

    init(sessionID: String, recordsStartup: Bool = true) {
        self.sessionID = sessionID
        self.recordsStartup = recordsStartup
    }

    func observe(_ engine: AetherEngine) {
        guard recordsStartup else { return }
        // Aether publishes its startup sequence on its MainActor owner.
        observation = engine.$startupProgress.removeDuplicates().sink { [weak self] progress in
            guard let self, let progress else { return }
            self.mark("checkpoint-\(progress.checkpoint)", generation: progress.generation)
        }
    }

    func mark(_ event: String, probeBytes: Int64? = nil, generation: UInt64? = nil) {
        guard recordsStartup else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), now - started)
        let uptime = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), now)
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_STARTUP session=\(sessionID) event=\(event)"
                + " elapsedSeconds=\(elapsed) uptimeSeconds=\(uptime)"
                + (generation.map { " generation=\($0)" } ?? "")
                + (event == "renderer-load-begin" ? " probeBytes=\(probeBytes.map(String.init) ?? "engine-default")" : "")
        )
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }
}
#endif
