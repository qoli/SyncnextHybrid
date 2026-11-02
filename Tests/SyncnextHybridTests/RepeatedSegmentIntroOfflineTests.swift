#if os(macOS)
import Foundation
import XCTest
@testable import SyncnextHybrid

/// User-checked music endings from frozen MDD episodes 1–9. The visual intro
/// ends earlier; the music's approximate 84–85-second ending is the target here.
final class RepeatedSegmentIntroOfflineTests: XCTestCase {
    private struct Catalog: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let episode: Int
        let analysisSeconds: Double
    }

    private struct PairResult: Codable {
        let previous: Int
        let current: Int
        let range: [Double]?
        let timeScale: Double?
        let elapsedSeconds: Double
    }

    func testFrozenMDDIntrosThroughProductionHLSDecoderWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["FINGERPRINT_INTRO_FIXTURES"] else {
            throw XCTSkip("Set FINGERPRINT_INTRO_FIXTURES to the frozen MDD intro directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        )
        let origin = try FingerprintOfflineOrigin(directory: directory)
        defer { origin.stop() }
        var artifacts: [Int: RepeatedSegmentFingerprintArtifact] = [:]
        for fixture in catalog.fixtures {
            let episodeDirectory = directory.appendingPathComponent(String(format: "ep%02d", fixture.episode))
            let batch = try await HybridIndependentFingerprintAudio.decode(
                source: .remoteHLS(HybridRemoteHLSAudioRequest(
                    url: origin.url.appendingPathComponent(String(format: "ep%02d/media.m3u8", fixture.episode)),
                    httpHeaders: [:],
                    selection: HybridRemoteHLSAudioSelection(displayName: nil, language: nil, optionOrdinal: 0)
                )),
                range: 0..<fixture.analysisSeconds
            )
            XCTAssertEqual(batch.provider, .independentRemoteHLS)
            let artifact = try RepeatedSegmentFingerprint.compute(
                audioBatch: batch, label: "mdd-ep\(fixture.episode)-front"
            )
            artifacts[fixture.episode] = artifact
            try PropertyListEncoder().encode(artifact).write(
                to: episodeDirectory.appendingPathComponent("production-front.plist")
            )
            print("INTRO_PRODUCTION episode=\(fixture.episode) frames=\(artifact.fingerprints.count) "
                + "segments=\(batch.segmentCount)")
        }
        var results: [PairResult] = []
        for current in 2...9 {
            let previous = current - 1
            let began = ProcessInfo.processInfo.systemUptime
            let match = try RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: XCTUnwrap(artifacts[previous]), current: XCTUnwrap(artifacts[current])
            )
            let result = PairResult(
                previous: previous, current: current,
                range: match.map { [$0.rightRange.lowerBound, $0.rightRange.upperBound] },
                timeScale: match?.alignmentTimeScale,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - began
            )
            results.append(result)
            print("INTRO_PRODUCTION previous=\(previous) current=\(current) "
                + "range=\(result.range?.description ?? "nil") scale=\(result.timeScale?.description ?? "nil")")
            let actual = try XCTUnwrap(match)
            XCTAssertLessThan(actual.rightRange.lowerBound, 1)
            // Approximate music ending checked by the user, not a production
            // duration rule. Include fingerprint-grid/decoder boundary error.
            XCTAssertEqual(actual.rightRange.upperBound, 84.5, accuracy: 1.5)
        }
        // A real-media negative control: ep1's opening music versus ep9's
        // visually checked dialogue after the opening, in source coordinates.
        let first = try XCTUnwrap(artifacts[1])
        let ninth = try XCTUnwrap(artifacts[9])
        let introFrames = 0..<780
        let dialogueFrames = 1_000..<1_780
        let music = RepeatedSegmentFingerprintArtifact(
            label: "ep1-music-negative-control", sourceStartSeconds: 0,
            fingerprints: Array(first.fingerprints[introFrames]),
            validity: Array(first.validity[introFrames])
        )
        let dialogue = RepeatedSegmentFingerprintArtifact(
            label: "ep9-dialogue-negative-control", sourceStartSeconds: 100,
            fingerprints: Array(ninth.fingerprints[dialogueFrames]),
            validity: Array(ninth.validity[dialogueFrames])
        )
        let unrelated = try RepeatedSegmentFingerprint.findBestPairwiseMatch(previous: music, current: dialogue)
        XCTAssertNil(unrelated, "Opening music must not match unrelated episode dialogue")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: directory.appendingPathComponent("production-analysis.json"))
    }
}
#endif
