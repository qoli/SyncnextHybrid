#if os(macOS)
import Foundation
import XCTest
@testable import SyncnextHybrid

/// 5ML-92 diagnostic probe, not full tvOS session acceptance.
/// The nested call is the independentRemoteHLS branch of fingerprintAudio;
/// the downloader and decoder below it are the real production implementations.
final class HybridFingerprintCancellationInvestigationTests: XCTestCase {
    func testOuterCancellationWhileFirstResourceBatchIsBlocked() async throws {
        let origin = try CancellationProbeOrigin()
        defer { origin.stop() }
        let source = origin.source
        let fingerprintRequest = HybridFingerprintAudioRequest(sourceRange: 0..<6)
        let outer = Task.detached(priority: .utility) {
            let batch: HybridFingerprintAudioBatch
            // Source-extracted tvOS session boundary; progress callback omitted.
            batch = try await Task.detached(priority: .utility) {
                try await HybridIndependentFingerprintAudio.decode(
                    source: source,
                    range: fingerprintRequest.sourceRange,
                    deadlineSeconds: fingerprintRequest.deadlineSeconds,
                    onProgress: nil
                )
            }.value
            return batch
        }
        defer { outer.cancel(); origin.releaseFirstBatch() }
        try await origin.waitForFirstBatch()
        origin.markCancellation()
        outer.cancel()
        XCTAssertTrue(outer.isCancelled)
        origin.releaseFirstBatch()
        let batch = try await outer.value
        let postCancel = origin.requestsAfterCancellation
        XCTAssertFalse(batch.buffers.isEmpty)
        XCTAssertEqual(batch.provider, .independentRemoteHLS)
        XCTAssertTrue(postCancel.contains("hevc-04.ts"))
        XCTAssertTrue(postCancel.contains("hevc-05.ts"))
        print("CANCEL_PROBE outer cancelled=true outcome=pcm-ready segments=\(batch.segmentCount) postCancel=\(postCancel.joined(separator: ","))")
    }

    func testDirectDecodeCancellationControl() async throws {
        let origin = try CancellationProbeOrigin()
        defer { origin.stop() }
        let source = origin.source
        let decode = Task.detached(priority: .utility) {
            try await HybridIndependentFingerprintAudio.decode(
                source: source,
                range: 0..<6
            )
        }
        defer { decode.cancel(); origin.releaseFirstBatch() }
        try await origin.waitForFirstBatch()
        origin.markCancellation()
        decode.cancel()
        origin.releaseFirstBatch()
        do {
            _ = try await decode.value
            XCTFail("The decoder's own cancelled task must observe cancellation")
        } catch is CancellationError {
            print("CANCEL_PROBE direct cancelled=true outcome=CancellationError postCancel=\(origin.requestsAfterCancellation.joined(separator: ","))")
        }
    }

    func testCursorCloseWhileFirstResourceBatchIsBlocked() async throws {
        let origin = try CancellationProbeOrigin()
        defer { origin.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard case .remoteHLS(let request) = origin.source else {
            return XCTFail("The probe must use the remote HLS production path")
        }
        let cursor = try await HybridHLSVODAudioSource.prepare(
            request: request,
            range: 0..<6,
            scope: .boundedRange,
            session: session
        )
        defer { cursor.close() }
        try await origin.waitForFirstBatch()
        origin.markCancellation()
        cursor.close()

        // The origin still holds all responses. Quiescence must come from
        // cancellation, not from releasing the server gate or completing data.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var pending = await session.allTasks
        while !pending.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
            pending = await session.allTasks
        }
        XCTAssertTrue(pending.isEmpty, "Cursor close must cancel held URLSession tasks")
        var bytes = [UInt8](repeating: 0, count: 16)
        let readResult = bytes.withUnsafeMutableBufferPointer {
            cursor.reader.read($0.baseAddress, size: Int32($0.count))
        }
        XCTAssertEqual(readResult, -1)
        let postCancel = origin.requestsAfterCancellation
        XCTAssertFalse(postCancel.contains("hevc-04.ts"))
        XCTAssertFalse(postCancel.contains("hevc-05.ts"))
        print("CANCEL_PROBE cursor-close pending=\(pending.count) read=\(readResult) gate=held postCancel=\(postCancel.joined(separator: ","))")
    }
}

private final class CancellationProbeOrigin: @unchecked Sendable {
    private let process = Process()
    private let directory: URL
    private let gate: URL
    private let cancel: URL
    private let log: URL
    let source: HybridIndependentFingerprintAudioSource

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("5ml92-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        gate = directory.appendingPathComponent("release")
        cancel = directory.appendingPathComponent("cancel")
        log = directory.appendingPathComponent("requests.jsonl")
        let fixtures = try XCTUnwrap(Bundle.module.url(
            forResource: "hevc", withExtension: "m3u8", subdirectory: "Fixtures/hevc-hls"
        )).deletingLastPathComponent()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", """
        import sys, pathlib, json, time, threading
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        root, state = sys.argv[1], pathlib.Path(sys.argv[2])
        lock = threading.Lock()
        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=root, **kwargs)
            def do_GET(self):
                name = self.path.rsplit('/', 1)[-1]
                with lock:
                    with (state / 'requests.jsonl').open('a') as f:
                        f.write(json.dumps({'path': name, 'afterCancel': (state / 'cancel').exists(), 'time': time.monotonic()}) + '\\n')
                if name.endswith('.ts'):
                    while not (state / 'release').exists():
                        time.sleep(0.01)
                try:
                    super().do_GET()
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Expected when the probe cancels the client connection.
            def log_message(self, *args): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """, fixtures.path, directory.path]
        process.standardOutput = output
        try process.run()
        var bytes = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            bytes.append(byte)
        }
        let port = try XCTUnwrap(String(data: bytes, encoding: .utf8).flatMap(Int.init))
        source = .remoteHLS(HybridRemoteHLSAudioRequest(
            url: URL(string: "http://127.0.0.1:\(port)/hevc.m3u8")!,
            httpHeaders: [:],
            selection: HybridRemoteHLSAudioSelection(displayName: nil, language: "zho", optionOrdinal: 1)
        ))
    }

    func waitForFirstBatch() async throws {
        // Harness timeout only: fail if acquisition never reaches the held batch.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        let firstBatch = Set((0..<4).map { String(format: "hevc-%02d.ts", $0) })
        while !firstBatch.isSubset(of: Set(requestRows.compactMap { $0["path"] as? String })) {
            guard process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "CancellationProbe", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The first four TS requests did not reach the test origin"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func markCancellation() {
        FileManager.default.createFile(atPath: cancel.path, contents: nil)
    }

    func releaseFirstBatch() {
        FileManager.default.createFile(atPath: gate.path, contents: nil)
    }

    var requestsAfterCancellation: [String] {
        requestRows.compactMap { row in
            guard row["afterCancel"] as? Bool == true else { return nil }
            return row["path"] as? String
        }
    }

    private var requestRows: [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return row
        }
    }

    func stop() {
        releaseFirstBatch()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
