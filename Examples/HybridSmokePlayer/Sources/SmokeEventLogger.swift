import CryptoKit
import Foundation
import SyncnextHybrid

struct SmokeRedactor: Sendable {
    private let sensitiveValues: [String]

    init(configuration: SmokeConfiguration) {
        sensitiveValues = (
            [configuration.sourceURL.absoluteString]
            + Array(configuration.httpHeaders.values)
        ).filter { !$0.isEmpty }
    }

    init(sensitiveValues: [String]) {
        self.sensitiveValues = sensitiveValues.filter { !$0.isEmpty }
    }

    func sanitize(_ value: String) -> String {
        sensitiveValues.reduce(value) { result, sensitive in
            result.replacingOccurrences(
                of: sensitive,
                with: "<redacted>"
            )
        }
    }
}

@MainActor
struct SmokeEventEmitter {
    private struct Record: Encodable {
        let schemaVersion: Int
        let timestamp: String
        let runID: String
        let event: String
        let sourceID: String
        let metrics: [String: String]
    }

    let runID: String
    let sourceID: String
    let redactor: SmokeRedactor

    init(configuration: SmokeConfiguration) {
        runID = UUID().uuidString.lowercased()
        sourceID = Self.sourceFingerprint(configuration.sourceURL)
        redactor = SmokeRedactor(configuration: configuration)
    }

    init(configurationFailure: Void) {
        runID = UUID().uuidString.lowercased()
        sourceID = "unavailable"
        redactor = SmokeRedactor(sensitiveValues: [])
    }

    func emit(
        _ event: String,
        metrics: [String: String] = [:]
    ) {
        let sanitizedMetrics = metrics.mapValues(redactor.sanitize)
        let record = Record(
            schemaVersion: 1,
            timestamp: Date().ISO8601Format(),
            runID: runID,
            event: event,
            sourceID: sourceID,
            metrics: sanitizedMetrics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            preconditionFailure(
                "Hybrid smoke event encoding failed: \(error)"
            )
        }
        guard let line = String(data: data, encoding: .utf8) else {
            preconditionFailure(
                "Hybrid smoke event encoding was not UTF-8"
            )
        }
        print("HYBRID_SMOKE_EVENT \(line)")
    }

    func metrics(
        for snapshot: HybridPlaybackSnapshot,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var values = [
            "mode": SmokePlaybackMode.hybridAVKit.rawValue,
            "route": snapshot.route.smokeName,
            "aether_backend": "not_applicable",
            "aether_current_avplayer": "not_applicable",
            "phase": snapshot.phase.smokeName,
            "current_time_seconds":
                Self.number(snapshot.currentTime),
            "duration_seconds": Self.number(snapshot.duration),
            "requested_rate": Self.number(Double(snapshot.rate)),
            "selected_audio_track":
                snapshot.selectedAudioTrackID.map(String.init) ?? "none",
            "selected_subtitle_track":
                snapshot.selectedSubtitleTrackID.map(String.init)
                ?? "none",
        ]
        values.merge(extra, uniquingKeysWith: { _, latest in latest })
        return values
    }

    func metrics(
        for snapshot: AetherSmokeSnapshot,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var values = [
            "mode": SmokePlaybackMode.aetherEngine.rawValue,
            "route": "not_applicable",
            "aether_backend": snapshot.backend.rawValue,
            "aether_current_avplayer":
                snapshot.hasCurrentAVPlayer ? "present" : "absent",
            "phase": snapshot.phase.smokeName,
            "current_time_seconds":
                Self.number(snapshot.currentTime),
            "duration_seconds": Self.number(snapshot.duration),
            "requested_rate":
                Self.number(Double(snapshot.requestedRate)),
            "video_width": String(snapshot.videoWidth),
            "video_height": String(snapshot.videoHeight),
            "audio_track_count": String(snapshot.audioTrackCount),
            "subtitle_track_count":
                String(snapshot.subtitleTrackCount),
        ]
        values.merge(extra, uniquingKeysWith: { _, latest in latest })
        return values
    }

    private static func sourceFingerprint(_ url: URL) -> String {
        let digest = SHA256.hash(
            data: Data(url.absoluteString.utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else {
            return "nonfinite"
        }
        return String(format: "%.3f", value)
    }
}

extension HybridPlaybackRoute {
    var smokeName: String {
        switch self {
        case .nativeAVPlayer:
            "nativeAVPlayer"
        case .avKitProxy:
            "avKitProxy"
        }
    }
}

extension HybridPlaybackPhase {
    var smokeName: String {
        switch self {
        case .idle:
            "idle"
        case .loading:
            "loading"
        case .playing:
            "playing"
        case .paused:
            "paused"
        case .seeking:
            "seeking"
        case .rebuffering:
            "rebuffering"
        case .stalled:
            "stalled"
        case .ended:
            "ended"
        case .failed:
            "failed"
        }
    }
}
