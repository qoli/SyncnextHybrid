#if os(macOS)
import AVFAudio
import Foundation
import XCTest
@testable import SyncnextHybrid

/// Opt-in real-media negative cases from MDD episodes 30–32.
/// Listening confirmed different outro audio, so missing matches are expected.
/// Media and signed source URLs remain outside the repository.
final class RepeatedSegmentOutroOfflineTests: XCTestCase {
    private struct Fixture: Decodable {
        let episode: Int
        let duration: Double
        let range: [Double]
    }

    private struct PairResult: Codable {
        let previous: Int
        let current: Int
        let matched: Bool
        let score: Double?
        let nullThreshold: Double?
        let previousRange: [Double]?
        let currentRange: [Double]?
    }

    func testFrozenMDDOutroPairsWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["FINGERPRINT_OUTRO_FIXTURES"] else {
            throw XCTSkip("Set FINGERPRINT_OUTRO_FIXTURES to the frozen media directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let fixtures = try JSONDecoder().decode(
            [Fixture].self,
            from: Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        )
        let origin = try OfflineOrigin(directory: directory)
        defer { origin.stop() }
        var artifacts: [Int: RepeatedSegmentFingerprintArtifact] = [:]
        for fixture in fixtures {
            let range = fixture.range[0]..<fixture.range[1]
            let batch = try await HybridIndependentFingerprintAudio.decode(
                source: .remoteHLS(HybridRemoteHLSAudioRequest(
                    url: origin.url.appendingPathComponent("ep\(fixture.episode)/media.m3u8"),
                    httpHeaders: [:],
                    selection: HybridRemoteHLSAudioSelection(
                        displayName: nil, language: nil, optionOrdinal: 0
                    )
                )),
                range: range
            )
            XCTAssertEqual(batch.provider, .independentRemoteHLS)
            XCTAssertEqual(batch.segmentCount, 17)
            let artifact = try RepeatedSegmentFingerprint.compute(
                audioBatch: batch,
                label: "mdd-ep\(fixture.episode)-back"
            )
            artifacts[fixture.episode] = artifact
            let episodeDirectory = directory.appendingPathComponent("ep\(fixture.episode)")
            try PropertyListEncoder().encode(artifact).write(
                to: episodeDirectory.appendingPathComponent("production-back.plist")
            )
            let first = try XCTUnwrap(batch.buffers.first)
            let audio = try AVAudioFile(
                forWriting: episodeDirectory.appendingPathComponent("production-back.wav"),
                settings: first.buffer.format.settings
            )
            for buffer in batch.buffers {
                try audio.write(from: buffer.buffer)
            }
            print("OUTRO_REPRO episode=\(fixture.episode) frames=\(artifact.fingerprints.count) "
                + "valid=\(artifact.validity.filter { $0 }.count) "
                + "sourceStart=\(artifact.sourceStartSeconds) segments=\(batch.segmentCount)")
        }
        var results: [PairResult] = []
        for (previous, current) in [(30, 30), (31, 31), (32, 32), (30, 31), (31, 32), (30, 32)] {
            let left = try XCTUnwrap(artifacts[previous])
            let right = try XCTUnwrap(artifacts[current])
            let match = try RepeatedSegmentFingerprint.findBestPairwiseMatch(previous: left, current: right)
            results.append(PairResult(
                previous: previous, current: current, matched: match != nil,
                score: match?.score, nullThreshold: match?.nullThreshold,
                previousRange: match.map { [$0.leftRange.lowerBound, $0.leftRange.upperBound] },
                currentRange: match.map { [$0.rightRange.lowerBound, $0.rightRange.upperBound] }
            ))
            if previous == current {
                XCTAssertNotNil(match, "Self-match must provide a working positive control")
            } else if (previous, current) == (30, 31) || (previous, current) == (31, 32) {
                XCTAssertNil(match, "Different outro audio must not produce a skip match")
            }
            print("OUTRO_REPRO previous=\(previous) current=\(current) matched=\(match != nil) "
                + "score=\(match?.score.description ?? "nil") "
                + "range=\(match.map { String(describing: $0.rightRange) } ?? "nil")")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: directory.appendingPathComponent("production-results.json"))
    }

    private final class OfflineOrigin {
        private let process = Process()
        let url: URL

        init(directory: URL) throws {
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-c", """
            import sys
            from functools import partial
            from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
            class Handler(SimpleHTTPRequestHandler):
                def log_message(self, *args): pass
            server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=sys.argv[1]))
            print(server.server_port, flush=True)
            server.serve_forever()
            """, directory.path]
            process.standardOutput = output
            try process.run()
            var bytes = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }
                bytes.append(byte)
            }
            let port = try XCTUnwrap(String(data: bytes, encoding: .utf8).flatMap(Int.init))
            url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        }

        func stop() {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
    }
}
#endif
