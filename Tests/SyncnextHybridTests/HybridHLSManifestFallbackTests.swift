import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridHLSManifestFallbackTests: XCTestCase {
    private static let sourceURL = URL(string: "https://fallback-fixture.invalid/redirected/movie.m3u8")!
    private static let manifest = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-TARGETDURATION:4
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-KEY:METHOD=NONE,URI="../keys/movie.key?token=fixture",IV=0x00000000000000000000000000000001
    #EXT-X-MAP:URI="init.mp4",BYTERANGE="120@0"
    #EXT-X-PROGRAM-DATE-TIME:2026-10-03T00:00:00Z
    #EXTINF:6.106633,
    #EXT-X-BYTERANGE:106596@120
    video.png
    #EXT-X-DISCONTINUITY
    #EXTINF:11.6115,
    https://segments-fixture.invalid/second.png?signature=fixture
    #EXT-X-ENDLIST
    """

    private func repair(_ text: String) throws -> HybridHLSManifestRepair? {
        guard case .media(let media) = try HLSPlaylistDocument.parse(text) else {
            XCTFail("Expected media fixture")
            return nil
        }
        return try HybridHLSManifestRepair.make(
            text: text, media: media, responseURL: Self.sourceURL
        )
    }

    func testRepairsTargetDurationAndPreservesResourceSemanticsWithCRLF() throws {
        let result = try XCTUnwrap(repair(Self.manifest.replacingOccurrences(of: "\n", with: "\r\n")))
        XCTAssertEqual(result.originalTargetDuration, 4)
        XCTAssertEqual(result.correctedTargetDuration, 12)
        XCTAssertEqual(result.maximumSegmentDuration, 11.6115)
        XCTAssertTrue(result.playlist.contains("#EXT-X-TARGETDURATION:12"))
        XCTAssertTrue(result.playlist.contains("https://fallback-fixture.invalid/redirected/video.png"))
        XCTAssertTrue(result.playlist.contains("URI=\"https://fallback-fixture.invalid/keys/movie.key?token=fixture\""))
        XCTAssertTrue(result.playlist.contains("URI=\"https://fallback-fixture.invalid/redirected/init.mp4\""))
        for tag in [
            "#EXTINF:6.106633,", "#EXTINF:11.6115,",
            "#EXT-X-BYTERANGE:106596@120", "BYTERANGE=\"120@0\"",
            "IV=0x00000000000000000000000000000001",
            "#EXT-X-DISCONTINUITY",
            "#EXT-X-PROGRAM-DATE-TIME:2026-10-03T00:00:00Z",
            "https://segments-fixture.invalid/second.png?signature=fixture",
        ] {
            XCTAssertTrue(result.playlist.contains(tag), tag)
        }
    }

    func testValidTargetDurationIsNotRewritten() throws {
        XCTAssertNil(try repair(Self.manifest.replacingOccurrences(of: "TARGETDURATION:4", with: "TARGETDURATION:12")))
        XCTAssertNil(try repair(Self.manifest.replacingOccurrences(of: "TARGETDURATION:4", with: "TARGETDURATION:30")))
    }

    func testBOMAndWhitespaceKeepManifestTags() throws {
        let text = "\u{FEFF}" + Self.manifest
            .split(separator: "\n")
            .map { "  " + $0 + "  " }
            .joined(separator: "\r\n \r\n")
        let result = try XCTUnwrap(repair(text))
        XCTAssertTrue(result.playlist.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(result.playlist.contains("#EXT-X-TARGETDURATION:12"))
        XCTAssertFalse(result.playlist.contains("%EF%BB%BF"))
    }

    func testEncryptedTagPreservationDoesNotExpandEncryptedAdmission() throws {
        guard case .media(let clearMedia) = try HLSPlaylistDocument.parse(Self.manifest) else {
            return XCTFail("Expected clear media metadata")
        }
        let encrypted = Self.manifest.replacingOccurrences(of: "METHOD=NONE", with: "METHOD=AES-128")
        XCTAssertThrowsError(try HLSPlaylistDocument.parse(encrypted))
        let result = try XCTUnwrap(HybridHLSManifestRepair.make(
            text: encrypted, media: clearMedia, responseURL: Self.sourceURL
        ))
        XCTAssertTrue(result.playlist.contains("METHOD=AES-128,URI=\"https://fallback-fixture.invalid/keys/movie.key?token=fixture\""))
    }

    func testTriggerUsesHLSTargetDurationRounding() throws {
        let fixture = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.49,\na.ts\n#EXT-X-ENDLIST"
        XCTAssertNil(try repair(fixture))
        XCTAssertEqual(try repair(fixture.replacingOccurrences(of: "4.49", with: "4.50"))?.correctedTargetDuration, 5)
    }

    func testLiveAndMissingOrDuplicateTargetAreNotRepaired() throws {
        XCTAssertNil(try repair(Self.manifest.replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")))
        XCTAssertNil(try repair(Self.manifest.replacingOccurrences(of: "#EXT-X-TARGETDURATION:4\n", with: "")))
        XCTAssertNil(try repair(Self.manifest.replacingOccurrences(of: "#EXT-X-TARGETDURATION:4", with: "#EXT-X-TARGETDURATION:4\n#EXT-X-TARGETDURATION:4")))
    }

    func testPlanServesOnlyManifestAndKeepsNativeHeadersAndAnalysisSource() async throws {
        let repaired = try XCTUnwrap(repair(Self.manifest))
        let request = try HybridPlaybackRequest(
            url: Self.sourceURL,
            httpHeaders: ["Origin": "https://player-fixture.invalid", "User-Agent": "FixturePlayer"]
        )
        let admission = HybridRemoteSourceAdmission.hlsVODRepairedManifest(repaired)
        let original = HybridPlaybackPlan.make(request: request, externalSubtitles: [], admission: admission)
        let prepared = try await original.prepareManifestFallback()
        let server = try XCTUnwrap(prepared.server)
        defer { server.stop() }
        XCTAssertEqual(request.url, Self.sourceURL)
        XCTAssertEqual(prepared.plan.sourceResolution, .repairedVODManifest)
        XCTAssertTrue(prepared.plan.options.nativeRemoteHLS)
        XCTAssertFalse(prepared.plan.options.isLive)
        XCTAssertEqual(prepared.plan.options.httpHeaders, request.httpHeaders)
        XCTAssertEqual(try HybridFingerprintAudioProviderResolver.resolve(admission: admission), .independentRemoteHLS)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: prepared.plan.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), repaired.playlist)
        var head = URLRequest(url: prepared.plan.url)
        head.httpMethod = "HEAD"
        let (headData, headResponse) = try await session.data(for: head)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(data.count))
        let unrelated = prepared.plan.url.deletingLastPathComponent().appendingPathComponent("video.png")
        let (_, unrelatedResponse) = try await session.data(from: unrelated)
        XCTAssertEqual((unrelatedResponse as? HTTPURLResponse)?.statusCode, 404)
        server.stop()
        do {
            _ = try await session.data(from: prepared.plan.url)
            XCTFail("Stopped fallback must not return a stale manifest")
        } catch { }
    }

    func testListenerIsReleasedWhenItsOwnerIsReleased() async throws {
        let repaired = try XCTUnwrap(repair(Self.manifest))
        var owner: HybridHLSManifestServer?
        weak var weakServer: HybridHLSManifestServer?
        do {
            let started = try await HybridHLSManifestServer.start(repair: repaired)
            owner = started.server
            weakServer = started.server
        }
        XCTAssertNotNil(owner)
        owner = nil
        XCTAssertNil(weakServer)
    }

    func testCancelledPreparationDoesNotProduceAPlaybackURL() async throws {
        let repaired = try XCTUnwrap(repair(Self.manifest))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HybridHLSManifestServer.start(repair: repaired)
        }
        do {
            let started = try await task.value
            started.server.stop()
            XCTFail("Cancelled preparation must fail")
        } catch is CancellationError { }
    }

    func testOnlyDirectFiniteMediaAdmissionUsesFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestFallbackFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let direct = try await HybridRemoteSourceAdmission.classify(
            url: URL(string: "https://fallback-fixture.invalid/movie.m3u8")!,
            httpHeaders: ["X-Fixture": "allowed"], session: session
        )
        guard case .hlsVODRepairedManifest(let repaired) = direct else {
            return XCTFail("Expected finite direct VOD repair")
        }
        XCTAssertEqual(repaired.correctedTargetDuration, 12)
        let master = try await HybridRemoteSourceAdmission.classify(
            url: URL(string: "https://fallback-fixture.invalid/master.m3u8")!,
            httpHeaders: ["X-Fixture": "allowed"], session: session
        )
        XCTAssertEqual(master, .hlsVOD)
    }
}

private final class ManifestFallbackFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let allowed = request.value(forHTTPHeaderField: "X-Fixture") == "allowed"
        let body: String
        if url.lastPathComponent == "master.m3u8" {
            body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nmovie.m3u8"
        } else if url.lastPathComponent == "movie.m3u8" {
            body = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:11.6115,\nvideo.png\n#EXT-X-ENDLIST"
        } else {
            body = "segment fixture"
        }
        let response = HTTPURLResponse(url: url, statusCode: allowed ? 200 : 403, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
