import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridMediaResponseTests: XCTestCase {
    private let source = String(repeating: "a", count: 64)

    func testActualTransportResponseFormatPreservesStatusAndIdentity() throws {
        // seq=500 is not an HTTP 500 (the original incident's diagnostic trap).
        let response = try XCTUnwrap(HybridMediaResponse(diagnosticLine:
            "MEDIA_REQUEST event=response request=example sourceID=\(source) "
                + "resourceID=\(source) transport=avio-held-http1 range=bytes=3296886784- "
                + "seq=500 uptimeMs=100 bytes=0 deltaBytes=0 cancelRequested=false "
                + "afterCancelBytes=0 finished=false status=404"
        ))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.sourceID, source)
        XCTAssertEqual(response.resourceID, source)
    }

    func testProgressAndUnclassifiedLinesCannotBecomeFailures() {
        for line in [
            "MEDIA_REQUEST event=progress sourceID=\(source) resourceID=\(source) seq=500 bytes=404",
            "MEDIA_REQUEST event=response sourceID=\(source) resourceID=\(source)",
            "MEDIA_REQUEST event=response sourceID=invalid resourceID=\(source) status=404",
            "unrelated event=response sourceID=\(source) resourceID=\(source) status=404",
        ] {
            XCTAssertNil(HybridMediaResponse(diagnosticLine: line))
        }
    }

    func testSourceRebindingPreservesOptionsAndExternalSubtitle() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/old"))
        let newURL = try XCTUnwrap(URL(string: "https://example.invalid/new"))
        let subtitle = HybridExternalSubtitle(url: url.appendingPathExtension("srt"), language: "zh")
        let request = try HybridPlaybackRequest(
            url: url, httpHeaders: ["Authorization": "old-fixture"], heldSourceConnection: true,
            externalSubtitles: [subtitle], preferredAudioLanguages: ["ja"],
            preferredSubtitleLanguages: ["zh"], preferredForwardBufferDuration: 30,
            preferDualLayerDolbyVision: true
        )
        let renewed = try request.replacingSource(url: newURL, httpHeaders: ["X-Fixture": "new"], initialPosition: 2364.74,
                                                 initialAudioTrackID: 2)
        XCTAssertEqual(renewed.url, newURL)
        XCTAssertEqual(renewed.httpHeaders, ["X-Fixture": "new"])
        XCTAssertEqual(renewed.initialPosition, 2364.74)
        XCTAssertEqual(renewed.initialAudioTrackID, 2)
        XCTAssertEqual(renewed.externalSubtitles, [subtitle])
        XCTAssertEqual(renewed.preferredAudioLanguages, ["ja"])
        XCTAssertEqual(renewed.preferredSubtitleLanguages, ["zh"])
        XCTAssertEqual(renewed.preferredForwardBufferDuration, 30)
        XCTAssertTrue(renewed.heldSourceConnection)
        XCTAssertTrue(renewed.preferDualLayerDolbyVision)
    }
}
