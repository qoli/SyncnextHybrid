#if os(macOS)
import Foundation
import XCTest

/// Serve frozen HLS resources over loopback for the real production decoder.
final class FingerprintOfflineOrigin {
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
#endif
