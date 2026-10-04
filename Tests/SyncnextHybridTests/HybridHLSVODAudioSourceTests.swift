import AetherEngine
import AVFAudio
import AetherLibavcodec
import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridHLSVODAudioSourceTests: XCTestCase {
    func testBoundedHLSCursorIncludesOneLookaheadSegment() throws {
        let document = try HLSMediaDocument(
            lines: """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:1
            #EXTINF:1,
            audio-00.ts
            #EXTINF:1,
            audio-01.ts
            #EXTINF:1,
            audio-02.ts
            #EXT-X-ENDLIST
            """.split(whereSeparator: \.isNewline).map(String.init)
        )

        let selected = document.prefixCovering(
            2,
            lookaheadSegmentCount: 1
        )

        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected.last?.resource.uri, "audio-02.ts")
    }

    func testBoundedHLSWindowPreservesGlobalTimelineOffset() throws {
        let document = try HLSMediaDocument(
            lines: """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:10
            #EXTINF:10,
            audio-00.ts
            #EXTINF:10,
            audio-01.ts
            #EXTINF:10,
            audio-02.ts
            #EXTINF:10,
            audio-03.ts
            #EXT-X-ENDLIST
            """.split(whereSeparator: \.isNewline).map(String.init)
        )

        let window = document.windowCovering(
            21..<29,
            lookaheadSegmentCount: 1
        )

        XCTAssertEqual(window.timelineOffset, 20, accuracy: 0.001)
        XCTAssertEqual(window.segments.count, 2)
        XCTAssertEqual(window.segments.first?.resource.uri, "audio-02.ts")
        XCTAssertEqual(window.segments.last?.resource.uri, "audio-03.ts")
    }

    func testFingerprintProviderResolutionIsExplicitPerAdmission() throws {
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsVOD
            ),
            .independentRemoteHLS
        )
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsVODPQOnlyMaster(
                    mediaPlaylistURL: URL(
                        string: "https://hybrid-fixture.invalid/video.m3u8"
                    )!,
                    duration: 120
                )
            ),
            .independentRemoteHLS
        )
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsVODHEVCMPEGTS(
                    duration: 120,
                    evidence: .standardStreamType(0x24)
                )
            ),
            .segmentCache
        )
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .aetherDefault(.confirmedNonHLS)
            ),
            .independentDemuxer
        )
        XCTAssertThrowsError(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsLive
            )
        ) { error in
            XCTAssertEqual(
                error as? HybridFingerprintAudioError,
                .liveOrDVRUnsupported
            )
        }
    }

    func testHEVCBackDoesNotUsePlaybackCache() throws {
        let admission = HybridRemoteSourceAdmission.hlsVODHEVCMPEGTS(
            duration: 2_700, evidence: .standardStreamType(0x24)
        )
        XCTAssertEqual(try HybridFingerprintAudioProviderResolver.resolve(admission: admission, region: .front), .segmentCache)
        XCTAssertEqual(try HybridFingerprintAudioProviderResolver.resolve(admission: admission, region: .back), .independentRemoteHLS)
        XCTAssertEqual(try HybridFingerprintAudioProviderResolver.resolve(admission: .hlsVOD, region: .back), .independentRemoteHLS)
    }

    func testOnlyMaterialFailuresPermitExtractorFallback() {
        for error: HybridFingerprintAudioError in [.sourceUnavailable, .discontinuousRange, .incompleteRange] {
            XCTAssertTrue(error.canUseIntroAudioExtraction)
        }
        for error: HybridFingerprintAudioError in [.invalidRange, .invalidDeadline, .deadlineExceeded,
                .liveOrDVRUnsupported, .audioTrackUnavailable, .sessionChanged, .sessionStopped] {
            XCTAssertFalse(error.canUseIntroAudioExtraction)
        }
    }

    #if os(macOS)
    func testExtractorNonzeroHLSRangeDoesNotDownloadPrefix() async throws {
        let server = try HLSExtractorTestServer()
        defer { server.stop() }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aac")
        defer {
            if FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.removeItem(at: output)
            }
        }
        let artifact = try await HybridIntroAudioExtractor.extract(
            request: HybridIntroAudioExtractionRequest(
                url: server.url,
                httpHeaders: ["X-Hybrid-Fixture": "allowed"],
                sourceRange: 2.5..<6, outputURL: output
            )
        )
        XCTAssertGreaterThan(artifact.packetCount, 0)
        XCTAssertEqual(artifact.sourceStartSeconds, 2.5, accuracy: 0.05)
        XCTAssertEqual(artifact.sourceStartSeconds + artifact.sourceDuration, 6, accuracy: 0.25)
        let paths = server.paths
        // Source admission may inspect the first TS once; range extraction must not fetch it again.
        XCTAssertLessThanOrEqual(paths.filter { $0 == "hevc-00.ts" }.count, 1)
        XCTAssertFalse(paths.contains("hevc-01.ts"))
        XCTAssertTrue(paths.contains("hevc-05.ts"))
    }

    func testDefaultHEVCTailPCMOnlyDownloadsItsBoundedWindow() async throws {
        let server = try HLSExtractorTestServer()
        defer { server.stop() }
        let batch = try await HybridIndependentFingerprintAudio.decode(
            source: .remoteHLS(HybridRemoteHLSAudioRequest(
                url: server.url, httpHeaders: ["X-Hybrid-Fixture": "allowed"],
                selection: HybridRemoteHLSAudioSelection(displayName: nil, language: "zho", optionOrdinal: 1)
            )),
            range: 2.5..<6
        )
        XCTAssertEqual(batch.provider, .independentRemoteHLS)
        let first = try XCTUnwrap(batch.buffers.first)
        let last = try XCTUnwrap(batch.buffers.last)
        XCTAssertEqual(first.sourceTime, 2.5, accuracy: 0.05)
        XCTAssertEqual(last.sourceTime + Double(last.buffer.frameLength) / last.buffer.format.sampleRate, 6, accuracy: 0.25)
        XCTAssertFalse(server.paths.contains("hevc-00.ts"))
        XCTAssertFalse(server.paths.contains("hevc-01.ts"))
        XCTAssertTrue(server.paths.contains("hevc-05.ts"))
        XCTAssertFalse(server.paths.contains("hevc-06.ts"))
        XCTAssertFalse(try RepeatedSegmentFingerprint.compute(audioBatch: batch, label: "tail").fingerprints.isEmpty)
    }

    func testExtractorSelectedAudioAndExistingFileMatcherForFrontAndBack() async throws {
        let server = try HLSExtractorTestServer()
        defer { server.stop() }
        for range in [0.0..<2.0, 2.5..<6.0] {
            let output = server.directory.appendingPathComponent(UUID().uuidString + ".aac")
            let audio = try await HybridIntroAudioExtractor.extract(
                request: HybridIntroAudioExtractionRequest(
                    url: server.url, httpHeaders: ["X-Hybrid-Fixture": "allowed"],
                    sourceRange: range, outputURL: output,
                    audioSelection: HybridRemoteHLSAudioSelection(
                        displayName: nil, language: "zho", optionOrdinal: 1
                    )
                )
            )
            XCTAssertEqual(audio.sourceStartSeconds, range.lowerBound, accuracy: 0.05)
            let artifact = try RepeatedSegmentFingerprint.compute(
                audioFileURL: audio.url, label: "fixture", sourceStartSeconds: audio.sourceStartSeconds
            )
            XCTAssertEqual(artifact.sourceStartSeconds, audio.sourceStartSeconds)
            XCTAssertFalse(artifact.fingerprints.isEmpty)
            let file = try AVAudioFile(forReading: audio.url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            var crossings = 0
            for index in 1..<Int(buffer.frameLength) {
                if (channel[index - 1] < 0) != (channel[index] < 0) { crossings += 1 }
            }
            let frequency = Double(crossings) / (Double(buffer.frameLength) / buffer.format.sampleRate) / 2
            XCTAssertEqual(frequency, 880, accuracy: 30)
        }
    }

    #endif

    func testDedicatedHLSVODRenditionBuildsIndependentFFmpegCursor()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridHLSFixtureURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = HybridRemoteHLSAudioRequest(
            url: try XCTUnwrap(
                URL(string: "https://hybrid-fixture.invalid/master.m3u8")
            ),
            httpHeaders: ["X-Hybrid-Fixture": "allowed"],
            selection: HybridRemoteHLSAudioSelection(
                displayName: "English",
                language: "en",
                optionOrdinal: 0
            )
        )
        let prepared = try await HybridHLSVODAudioSource.prepare(
            request: request,
            range: 0..<2,
            session: session
        )
        defer { prepared.close() }

        let demuxer = Demuxer()
        try demuxer.openIndependent(
            reader: prepared.reader,
            formatHint: prepared.formatHint
        )
        defer { demuxer.close() }
        XCTAssertTrue(prepared.usesDedicatedAudioRendition)
        let selected = try
            HybridHLSVODAudioSource.resolveSelectedTrack(
                from: demuxer.audioTrackInfos(),
                prepared: prepared
        )
        XCTAssertEqual(selected.codec, "aac")
        let stream = try XCTUnwrap(
            demuxer.stream(at: Int32(selected.id))
        )
        demuxer.discardAllStreamsExcept([Int32(selected.id)])

        let decoder = HybridFFmpegAudioDecoder()
        try decoder.open(stream: stream)
        defer { decoder.close() }
        var decoded = [HybridDecodedAudioChunk]()
        while decoded.isEmpty, let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&packetToFree) }
            guard packet.pointee.stream_index == selected.id else {
                continue
            }
            decoded.append(
                contentsOf: try decoder.decode(packet: packet)
            )
        }
        let first = try XCTUnwrap(decoded.first)
        XCTAssertEqual(
            first.ptsSeconds - demuxer.formatStartTimeSeconds,
            0,
            accuracy: 0.025
        )
    }

    func testHLSWithoutEndListFailsAsLiveOrDVR() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridHLSFixtureURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = HybridRemoteHLSAudioRequest(
            url: try XCTUnwrap(
                URL(string: "https://hybrid-fixture.invalid/live.m3u8")
            ),
            httpHeaders: [:],
            selection: HybridRemoteHLSAudioSelection(
                displayName: nil,
                language: nil,
                optionOrdinal: nil
            )
        )

        do {
            _ = try await HybridHLSVODAudioSource.prepare(
                request: request,
                range: 0..<1,
                session: session
            )
            XCTFail("live playlist unexpectedly admitted")
        } catch let error as HybridAudioAnalysisError {
            XCTAssertEqual(error, .liveOrDVRUnsupported)
        }
    }

    func testRemoteHLSFingerprintAdapterReturnsBoundedPCM() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridHLSFixtureURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = HybridRemoteHLSAudioRequest(
            url: try XCTUnwrap(
                URL(string: "https://hybrid-fixture.invalid/master.m3u8")
            ),
            httpHeaders: ["X-Hybrid-Fixture": "allowed"],
            selection: HybridRemoteHLSAudioSelection(
                displayName: "English",
                language: "en",
                optionOrdinal: 0
            )
        )
        let source = HybridIndependentFingerprintAudioSource.remoteHLS(
            request
        )
        let batch = try await HybridIndependentFingerprintAudio.decode(
            source: source,
            range: 0..<2,
            hlsSession: session
        )

        XCTAssertEqual(batch.provider, .independentRemoteHLS)
        XCTAssertGreaterThan(batch.segmentCount, 0)
        XCTAssertFalse(batch.buffers.isEmpty)
        XCTAssertEqual(batch.sourceRange, 0..<2)
        XCTAssertEqual(batch.cacheWaitSeconds, 0)
    }

    func testDirectDemuxFingerprintAdapterReturnsBoundedPCM() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )
        let batch = try await HybridIndependentFingerprintAudio.decode(
            source: source,
            range: 0..<1
        )

        XCTAssertEqual(batch.provider, .independentDemuxer)
        XCTAssertEqual(batch.segmentCount, 0)
        XCTAssertFalse(batch.buffers.isEmpty)
        XCTAssertEqual(batch.sourceRange, 0..<1)
        XCTAssertEqual(batch.cacheWaitSeconds, 0)
    }

    @MainActor
    func testDirectDemuxFingerprintAdapterReportsSourceTimeProgress()
        async throws
    {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )
        var updates = [HybridFingerprintAudioProgress]()

        _ = try await HybridIndependentFingerprintAudio.decode(
            source: source,
            range: 0..<1,
            onProgress: { progress in
                updates.append(progress)
            }
        )

        let decoding = updates.filter { $0.phase == .decoding }
        XCTAssertFalse(decoding.isEmpty)
        XCTAssertEqual(decoding.last?.provider, .independentDemuxer)
        XCTAssertGreaterThan(decoding.last?.sourceTime ?? 0, 0.9)
        XCTAssertGreaterThan(decoding.last?.fraction ?? 0, 0.9)
        XCTAssertTrue(
            zip(decoding, decoding.dropFirst()).allSatisfy { pair in
                pair.0.fraction <= pair.1.fraction
            }
        )
    }

    func testDirectDemuxFingerprintAdapterEnforcesOverallDeadline()
        async throws
    {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )

        do {
            _ = try await HybridIndependentFingerprintAudio.decode(
                source: source,
                range: 0..<1,
                deadlineSeconds: .leastNonzeroMagnitude
            )
            XCTFail("expired fingerprint deadline unexpectedly completed")
        } catch let error as HybridFingerprintAudioError {
            XCTAssertEqual(error, .deadlineExceeded)
        }
    }

    func testFingerprintRequestRejectsInvalidDeadline() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )

        do {
            _ = try await HybridIndependentFingerprintAudio.decode(
                source: source,
                range: 0..<1,
                deadlineSeconds: 0
            )
            XCTFail("invalid fingerprint deadline unexpectedly completed")
        } catch let error as HybridFingerprintAudioError {
            XCTAssertEqual(error, .invalidDeadline)
        }
    }

    func testDirectDemuxFingerprintAdapterAcceptsSmallTrailingShortfall()
        async throws
    {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )

        let batch = try await HybridIndependentFingerprintAudio.decode(
            source: source,
            range: 0..<2.18
        )

        XCTAssertEqual(batch.sourceRange, 0..<2.18)
        XCTAssertFalse(batch.buffers.isEmpty)
    }

    func testDirectDemuxFingerprintAdapterRejectsLargeTrailingShortfall()
        async throws
    {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )

        do {
            _ = try await HybridIndependentFingerprintAudio.decode(
                source: source,
                range: 0..<2.3
            )
            XCTFail("large trailing shortfall unexpectedly admitted")
        } catch let error as HybridFingerprintAudioError {
            XCTAssertEqual(error, .incompleteRange)
        }
    }
}

private final class HybridHLSFixtureURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        request.url?.host == "hybrid-fixture.invalid"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.value(
            forHTTPHeaderField: "X-Hybrid-Fixture"
        ) == "allowed" || request.url?.lastPathComponent == "live.m3u8",
              let url = request.url,
              let data = fixtureData(for: url.lastPathComponent),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(data.count),
                ]
              ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fixtureData(for name: String) -> Data? {
        if name == "live.m3u8" {
            return Data(
                """
                #EXTM3U
                #EXT-X-VERSION:3
                #EXT-X-TARGETDURATION:1
                #EXTINF:1,
                audio-00.ts
                """.utf8
            )
        }
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let url = Bundle.module.url(
                forResource: String(parts[0]),
                withExtension: String(parts[1]),
                subdirectory: name.hasPrefix("hevc") ? "Fixtures/hevc-hls" : "Fixtures/hls-vod"
              ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}

#if os(macOS)
private final class HLSExtractorTestServer {
    let process = Process()
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = try XCTUnwrap(Bundle.module.url(
            forResource: "hevc", withExtension: "m3u8", subdirectory: "Fixtures/hevc-hls"
        )).deletingLastPathComponent()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", """
        import sys, pathlib
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=sys.argv[1], **kwargs)
            def do_GET(self):
                with open(sys.argv[2], 'a') as log:
                    log.write(self.path.rsplit('/', 1)[-1] + '\\n')
                if self.headers.get('X-Hybrid-Fixture') != 'allowed':
                    self.send_error(403)
                    return
                super().do_GET()
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """, fixtures.path, directory.appendingPathComponent("requests.txt").path]
        process.standardOutput = output
        try process.run()
        var bytes = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            bytes.append(byte)
        }
        let port = try XCTUnwrap(String(data: bytes, encoding: .utf8).flatMap(Int.init))
        url = URL(string: "http://127.0.0.1:\(port)/hevc.m3u8")!
    }

    var paths: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("requests.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
