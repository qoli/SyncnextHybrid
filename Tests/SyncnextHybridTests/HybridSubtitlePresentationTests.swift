import AetherEngine
import CoreGraphics
import XCTest
@testable import SyncnextHybrid

final class HybridSubtitlePresentationTests: XCTestCase {
    func testSourcePTSSelectsOverlappingCuesAndExpiresAtEnd() {
        let cues = [
            SubtitleCue(id: 1, startTime: 900, endTime: 904, body: .text("第一行")),
            SubtitleCue(id: 2, startTime: 902, endTime: 906, body: .text("第二行")),
        ]
        XCTAssertEqual(activeIDs(cues, at: 900), [1])
        XCTAssertEqual(activeIDs(cues, at: 903), [1, 2])
        XCTAssertEqual(activeIDs(cues, at: 904), [2])
        XCTAssertEqual(activeIDs(cues, at: 906), [])
        // A seek back must show the earlier cue again; UI time is not source PTS.
        XCTAssertEqual(activeIDs(cues, at: 901), [1])
        XCTAssertEqual(activeIDs(cues, at: 1), [])
        XCTAssertEqual(activeIDs(cues, at: .nan), [])
    }

    func testClearingCuesRemovesPausedSubtitle() {
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("字幕"))
        XCTAssertEqual(activeIDs([cue], at: 5), [1])
        XCTAssertEqual(activeIDs([], at: 5), [])
    }

    func testLetterboxedVideoRectUsesDisplayAspect() {
        XCTAssertEqual(
            HybridSubtitlePresentation.videoRect(
                in: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                videoSize: CGSize(width: 1920, height: 800)
            ),
            CGRect(x: 0, y: 140, width: 1920, height: 800)
        )
    }

    func testBitmapCanvasCanExtendIntoLetterbox() {
        let rect = HybridSubtitlePresentation.imageRect(
            position: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1),
            canvasSize: CGSize(width: 1920, height: 1080),
            videoRect: CGRect(x: 0, y: 140, width: 1920, height: 800)
        )
        XCTAssertEqual(rect.minX, 480, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 864, accuracy: 0.001)
        XCTAssertEqual(rect.size, CGSize(width: 960, height: 108))
    }

    func testBitmapWithoutCanvasUsesVideoGeometry() {
        let rect = HybridSubtitlePresentation.imageRect(
            position: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1),
            canvasSize: .zero,
            videoRect: CGRect(x: 100, y: 140, width: 1000, height: 800)
        )
        XCTAssertEqual(rect, CGRect(x: 350, y: 780, width: 500, height: 80))
    }

    func testDefaultTextStacksAbovePreviousCue() {
        let video = CGRect(x: 0, y: 140, width: 1920, height: 800)
        let first = HybridSubtitlePresentation.textRect(
            size: CGSize(width: 400, height: 50),
            placement: nil,
            videoRect: video,
            bottomOffset: 0
        )
        let second = HybridSubtitlePresentation.textRect(
            size: CGSize(width: 300, height: 50),
            placement: nil,
            videoRect: video,
            bottomOffset: 50
        )
        XCTAssertEqual(first.midX, video.midX)
        XCTAssertEqual(first.maxY, 900)
        XCTAssertEqual(second.maxY, first.minY)
    }

    func testASSAlignmentAndPositionUseVideoCoordinates() {
        let rect = HybridSubtitlePresentation.textRect(
            size: CGSize(width: 300, height: 50),
            placement: SubtitleTextPlacement(
                alignment: 9,
                position: CGPoint(x: 0.8, y: 0.1)
            ),
            videoRect: CGRect(x: 100, y: 200, width: 1000, height: 600),
            bottomOffset: 0
        )
        XCTAssertEqual(rect, CGRect(x: 600, y: 260, width: 300, height: 50))
    }

    private func activeIDs(_ cues: [SubtitleCue], at time: Double) -> [Int] {
        HybridSubtitlePresentation.activeCues(cues, sourceTime: time).map(\.id)
    }
}
