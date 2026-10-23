#if DEBUG && os(macOS)
import AetherEngine
import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridVODRangeTestReaderTests: XCTestCase {
    func testSingleAndDualDeliverIdenticalOrderedBytesWithBoundedWindows() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        for mode in HybridVODRangeTestMode.allCases {
            let reader = try await Self.open(origin, mode: mode)
            defer { reader.close() }
            let result = await Task.detached { Self.drain(reader) }.value
            XCTAssertEqual(result.terminal, 0)
            XCTAssertEqual(result.data.count, origin.size)
            XCTAssertEqual(result.data, Data((0..<origin.size).map { UInt8($0 % 251) }))
            let observed = reader.observation
            XCTAssertEqual(observed.peakActiveRequests, mode.requestCount)
            XCTAssertEqual(observed.peakActiveResponses, mode.requestCount)
            XCTAssertLessThanOrEqual(observed.peakBufferedBytes, 16 * 1024 * 1024)
            XCTAssertEqual(observed.deliveredBytes, Int64(origin.size))
            XCTAssertNil(observed.failure)
            let trace = reader.drainTrace()
            let finished = trace.flatMap(\.requests).filter { !$0.metadata && $0.outcome == "completed" }
            XCTAssertFalse(finished.isEmpty)
            XCTAssertTrue(finished.allSatisfy { $0.firstBodyAt != nil && $0.finishedAt != nil })
            XCTAssertTrue(finished.contains { $0.transactions?.isEmpty == false }, "Real HTTP must reach the metrics callback")
            XCTAssertGreaterThan(observed.activity.singleResponseSeconds, 0)
            if mode == .dual { XCTAssertGreaterThan(observed.activity.dualResponseSeconds, 0) }
            else { XCTAssertEqual(observed.activity.dualResponseSeconds, 0) }
            XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_END), Int64(origin.size))
        }
        XCTAssertTrue(origin.requests.allSatisfy { $0["authorized"] as? Bool == true })
        XCTAssertTrue(origin.requests.filter { ($0["lower"] as? Int) != 0 || ($0["upper"] as? Int) != 0 }
            .allSatisfy { $0["if_range"] as? String == "\"range-fixture-v1\"" })
    }

    func testPartialBodyIsDeliveredBeforeWholeRangeFinishes() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        let reader = try await Self.open(origin, scenario: "partial-gated", mode: .dual)
        defer { reader.close() }
        let sample = await Task.detached { Self.read(reader, count: 64 * 1024) }.value
        XCTAssertGreaterThan(sample.count, 0)
        XCTAssertLessThanOrEqual(sample.count, 64 * 1024)
        XCTAssertEqual(reader.observation.requestsCompleted, 1, "Only the one-byte metadata probe has completed")
        XCTAssertEqual(sample.data, Data((0..<sample.count).map { UInt8($0 % 251) }))
    }

    func testSeekDiscardsOldWindowAndIndependentReaderHasOwnCursor() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        let reader = try await Self.open(origin, scenario: "partial-gated", mode: .dual)
        defer { reader.close() }
        _ = await Task.detached { Self.read(reader, count: 1024) }.value
        let target = HybridRangeTestReader.rangeBytes * 3 + 17
        XCTAssertEqual(reader.seek(offset: target, whence: SEEK_SET), target)
        origin.release()
        let sample = await Task.detached { Self.read(reader, count: 4096) }.value
        XCTAssertGreaterThan(sample.count, 0)
        let expected = Data((Int(target)..<(Int(target) + Int(sample.count))).map { UInt8($0 % 251) })
        XCTAssertEqual(sample.data, expected)
        let child = try XCTUnwrap(reader.makeIndependentReader())
        defer { child.close() }
        let side = await Task.detached { Self.read(child, count: 1024) }.value
        XCTAssertEqual(side.data, Data((0..<side.count).map { UInt8($0 % 251) }))
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_CUR), target + Int64(sample.count))
        XCTAssertGreaterThan(reader.observation.requestsCancelled, 0)
        XCTAssertEqual(reader.observation.independentReaders, 1)
        XCTAssertGreaterThan(reader.observation.independentSourceBytes, 0)
        reader.close()
        XCTAssertEqual(Self.read(reader, count: 1).count, -1)
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_SET), -1)
    }

    func testCancelUnblocksReadAndExplicitRepositionReopensRetainedReader() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        let reader = try await Self.open(origin, scenario: "body-gated", mode: .dual)
        defer { reader.close() }
        let finished = expectation(description: "cancelled read returns")
        let reading = Task.detached {
            let result = Self.read(reader, count: 1024)
            finished.fulfill()
            return result
        }
        try await origin.waitForRequests(3)
        reader.cancel()
        await fulfillment(of: [finished], timeout: 2)
        let aborted = await reading.value
        XCTAssertEqual(aborted.count, -1)
        XCTAssertEqual(reader.observation.activeRequests, 0)
        XCTAssertEqual(reader.seek(offset: 7, whence: SEEK_SET), 7)
        origin.release()
        let next = await Task.detached { Self.read(reader, count: 1024) }.value
        XCTAssertGreaterThan(next.count, 0)
        XCTAssertEqual(next.data, Data((7..<(7 + next.count)).map { UInt8($0 % 251) }))
        XCTAssertNil(reader.observation.failure)
    }

    func testMetadataPreparationCancellationDoesNotWaitForHTTPTimeout() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        let finished = expectation(description: "cancelled preparation returns")
        let opening = Task {
            defer { finished.fulfill() }
            return try await Self.open(origin, scenario: "metadata-gated", mode: .single)
        }
        try await origin.waitForRequests(1)
        opening.cancel()
        await fulfillment(of: [finished], timeout: 2)
        do {
            let unexpected = try await opening.value
            unexpected.close()
            XCTFail("Cancelled open unexpectedly succeeded")
        } catch { }
    }

    func testInvalidRangeResponsesFailExplicitlyWithoutWholeFileFallback() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        for scenario in ["wrong-range", "ignore-range", "weak-etag", "encoded", "invalid-date", "future-date"] {
            do {
                let unexpected = try await Self.open(origin, scenario: scenario, mode: .dual)
                unexpected.close()
                XCTFail("Invalid metadata response accepted: \(scenario)")
            } catch { XCTAssertTrue(error is HybridRangeTestReader.Failure) }
        }
        XCTAssertEqual(origin.requests.count, 6, "One bounded probe per failure, no alternate source or retry")
    }

    func testProviderHashOrAbsentETagUsesStrongHTTPDateAndRejectsChangedDate() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        for scenario in ["unquoted-etag", "date-only"] {
            let reader = try await Self.open(origin, scenario: scenario, mode: .dual)
            defer { reader.close() }
            XCTAssertEqual(reader.observation.validator, "Last-Modified")
            let sample = await Task.detached { Self.read(reader, count: 1024) }.value
            XCTAssertGreaterThan(sample.count, 0)
            XCTAssertNil(reader.observation.failure)
        }
        XCTAssertTrue(origin.requests.filter { ($0["upper"] as? Int) != 0 }
            .allSatisfy { $0["if_range"] as? String == "Mon, 05 Oct 2020 11:46:20 GMT" })
        let reader = try await Self.open(origin, scenario: "changed-date", mode: .single)
        defer { reader.close() }
        let changed = await Task.detached { Self.drain(reader) }.value
        XCTAssertEqual(changed.terminal, -1)
        XCTAssertEqual(reader.observation.failure, "identityChanged")
    }

    func testChangedRepresentationAndShortBodyAreReadErrorsInsteadOfEOF() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        for scenario in ["changed-etag", "short-body"] {
            let reader = try await Self.open(origin, scenario: scenario, mode: .single)
            defer { reader.close() }
            let result = await Task.detached { Self.drain(reader) }.value
            XCTAssertEqual(result.terminal, -1)
            XCTAssertNotNil(reader.observation.failure)
            XCTAssertEqual(reader.observation.requestsStarted, 2)
        }
    }

    func testEngineRequestedReopenAfterReadFailureStartsNewEpochAndKeepsFailureEvidence() async throws {
        let origin = try RangeTestOrigin()
        defer { origin.stop() }
        let reader = try await Self.open(origin, scenario: "short-body-once", mode: .single)
        defer { reader.close() }
        let failed = await Task.detached { Self.drain(reader) }.value
        XCTAssertEqual(failed.terminal, -1)
        reader.cancel() // CustomIOReaderBridge teardown before a retained-reader reopen
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_SET), 0)
        let reopened = await Task.detached { Self.drain(reader) }.value
        XCTAssertEqual(reopened.terminal, 0)
        XCTAssertEqual(reopened.data.count, origin.size)
        XCTAssertNotNil(reader.observation.failure, "The Probe must still report this run's source failure")
    }

    private static func open(_ origin: RangeTestOrigin, scenario: String = "valid", mode: HybridVODRangeTestMode) async throws -> HybridRangeTestReader {
        try await HybridRangeTestReader.open(
            url: origin.url.appendingPathComponent(scenario), headers: ["X-Range-Fixture": "allowed"], mode: mode
        )
    }

    private static func read(_ reader: IOReader, count: Int) -> (count: Int32, data: Data) {
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(count)) }
        return (result, result > 0 ? Data(buffer.prefix(Int(result))) : Data())
    }

    private static func drain(_ reader: IOReader) -> (terminal: Int32, data: Data) {
        var data = Data()
        while true {
            let sample = read(reader, count: 256 * 1024)
            if sample.count <= 0 { return (sample.count, data) }
            data.append(sample.data)
        }
    }
}

/// Real HTTP streaming fixture: out-of-order completion, partial delivery and
/// held bodies exercise URLSession's delegate/cancellation boundary directly.
private final class RangeTestOrigin: @unchecked Sendable {
    private let process = Process()
    private let termination = DispatchGroup()
    private let directory: URL
    private let gate: URL
    private let log: URL
    let url: URL
    let size = 16 * 1024 * 1024 + 37

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("range-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        gate = directory.appendingPathComponent("release")
        log = directory.appendingPathComponent("requests.jsonl")
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", """
        import sys, pathlib, json, time, threading, re
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        root, size = pathlib.Path(sys.argv[1]), int(sys.argv[2])
        lock = threading.Lock()
        pattern = bytes(range(251))
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                match = re.fullmatch(r'bytes=(\\d+)-(\\d+)', self.headers.get('Range', ''))
                if not match:
                    self.send_error(400); return
                lower, upper = map(int, match.groups())
                metadata = lower == upper == 0
                scenario = self.path.strip('/')
                short_once = False
                if scenario == 'short-body-once' and not metadata:
                    with lock:
                        marker = root / 'shortened'
                        short_once = not marker.exists()
                        marker.touch()
                with lock:
                    with (root / 'requests.jsonl').open('a') as file:
                        file.write(json.dumps({'lower': lower, 'upper': upper,
                          'authorized': self.headers.get('X-Range-Fixture') == 'allowed',
                          'if_range': self.headers.get('If-Range')}) + '\\n')
                status = 200 if scenario == 'ignore-range' else 206
                self.send_response(status)
                start = lower + 1 if scenario == 'wrong-range' else lower
                self.send_header('Content-Range', f'bytes {start}-{upper}/{size}')
                tag = '"changed"' if scenario == 'changed-etag' and not metadata else '"range-fixture-v1"'
                if scenario == 'weak-etag': tag = 'W/' + tag
                if scenario in ('unquoted-etag', 'changed-date'): tag = 'a' * 32
                if scenario not in ('date-only', 'invalid-date', 'future-date'):
                    self.send_header('ETag', tag)
                if scenario in ('unquoted-etag', 'date-only', 'changed-date'):
                    modified = 'Mon, 05 Oct 2020 11:46:20 GMT'
                    if scenario == 'changed-date' and not metadata: modified = 'Tue, 06 Oct 2020 11:46:20 GMT'
                    self.send_header('Last-Modified', modified)
                if scenario == 'invalid-date': self.send_header('Last-Modified', 'not-a-date')
                if scenario == 'future-date': self.send_header('Last-Modified', self.date_time_string(time.time() + 60))
                if scenario == 'encoded': self.send_header('Content-Encoding', 'gzip')
                length = upper - lower + 1
                self.send_header('Content-Length', str(length))
                self.end_headers()
                try:
                    if (scenario == 'metadata-gated' and metadata) or (scenario == 'body-gated' and not metadata):
                        while not (root / 'release').exists(): time.sleep(0.005)
                    delivered = 0
                    while delivered < length:
                        n = min(8192, length - delivered)
                        offset = (lower + delivered) % 251
                        chunk = (pattern * ((n + 501) // 251))[offset:offset+n]
                        self.wfile.write(chunk); self.wfile.flush()
                        delivered += n
                        if not metadata and (scenario == 'short-body' or short_once): return
                        if not metadata and scenario == 'partial-gated' and delivered >= 65536:
                            while not (root / 'release').exists(): time.sleep(0.005)
                        if not metadata: time.sleep(0.001 if lower >= 4194304 else 0.002)
                except (BrokenPipeError, ConnectionResetError): pass
            def log_message(self, *args): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """, directory.path, String(size)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        termination.enter()
        process.terminationHandler = { [termination] _ in termination.leave() }
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 {
            line.append(byte)
        }
        guard let portText = String(data: line, encoding: .utf8), let port = Int(portText),
              let endpoint = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate()
            throw NSError(domain: "RangeTestOrigin", code: 1)
        }
        url = endpoint
    }

    var requests: [[String: Any]] {
        guard let data = try? Data(contentsOf: log), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func waitForRequests(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while requests.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(requests.count, count)
    }

    func release() { FileManager.default.createFile(atPath: gate.path, contents: Data()) }

    func stop() {
        release()
        if process.isRunning { process.terminate() }
        XCTAssertEqual(termination.wait(timeout: .now() + 5), .success, "Fixture process must exit")
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
