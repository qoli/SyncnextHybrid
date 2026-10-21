#if os(tvOS)
import AetherEngine
import UIKit
import XCTest
@testable import SyncnextHybrid

final class HybridSubtitleOverlayViewTests: XCTestCase {
    @MainActor
    func testTextAppearsOnSourceClockAndClearsWhenDisabled() async throws {
        let overlay = makeOverlay()
        let cue = SubtitleCue(
            id: 1, startTime: 100, endTime: 110,
            body: .text("繁體中文字幕")
        )
        overlay.update(cues: [cue], sourceTime: 105, videoSize: videoSize)
        overlay.layoutIfNeeded()
        let label = try XCTUnwrap(overlay.subviews.first as? UILabel)
        XCTAssertEqual(label.attributedText?.string, "繁體中文字幕")
        XCTAssertGreaterThan(label.frame.width, 0)
        XCTAssertGreaterThan(label.frame.height, 0)
        XCTAssertTrue(overlay.bounds.contains(label.frame))
        XCTAssertFalse(overlay.isOpaque)
        XCTAssertFalse(overlay.isUserInteractionEnabled)

        // Pausing leaves the same valid line in place.
        overlay.update(cues: [cue], sourceTime: 105, videoSize: videoSize)
        XCTAssertTrue(overlay.subviews.first === label)
        // Off clears even though the media clock has not moved.
        overlay.update(cues: [], sourceTime: 105, videoSize: videoSize, cuesChanged: true)
        XCTAssertTrue(overlay.subviews.isEmpty)
        // A decoded cue that arrives after its end must never flash on screen.
        overlay.update(cues: [cue], sourceTime: 110, videoSize: videoSize)
        XCTAssertTrue(overlay.subviews.isEmpty)
    }

    @MainActor
    func testSwitchingTracksReplacesTextEvenWithSameCueIDAndTime() async throws {
        let overlay = makeOverlay()
        overlay.update(
            cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("繁體"))],
            sourceTime: 5, videoSize: videoSize
        )
        overlay.update(
            cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .richText([
                SubtitleTextRun(text: "简体", color: SubtitleColor(r: 0, g: 255, b: 0), isBold: true),
            ]))],
            sourceTime: 5, videoSize: videoSize, cuesChanged: true
        )
        overlay.layoutIfNeeded()
        let label = try XCTUnwrap(overlay.subviews.first as? UILabel)
        let text = try XCTUnwrap(label.attributedText)
        XCTAssertEqual(overlay.subviews.count, 1)
        XCTAssertEqual(text.string, "简体")
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .green)
    }

    @MainActor
    func testPlainSubtitleRendersSolidWhiteFill() async throws {
        let overlay = makeOverlay()
        overlay.update(
            cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("█"))],
            sourceTime: 5, videoSize: videoSize
        )
        overlay.layoutIfNeeded()
        let label = try XCTUnwrap(overlay.subviews.first as? UILabel)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: label.bounds, format: format).image {
            label.layer.render(in: $0.cgContext)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let counts = try pixels.withUnsafeMutableBytes { buffer -> (painted: Int, white: Int) in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: label.bounds)
            var painted = 0
            var white = 0
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                guard buffer[offset + 3] > 200 else { continue }
                painted += 1
                if buffer[offset] > 240, buffer[offset + 1] > 240, buffer[offset + 2] > 240 {
                    white += 1
                }
            }
            return (painted, white)
        }
        XCTAssertGreaterThan(counts.painted, 0)
        XCTAssertGreaterThan(
            Double(counts.white) / Double(max(counts.painted, 1)), 0.5,
            "The glyph body must stay solid white, rather than a dark embossed outline."
        )
    }

    @MainActor
    func testBitmapIsPresentedInItsSourceCanvasPosition() async throws {
        let overlay = makeOverlay()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let bitmap = SubtitleImage(
            cgImage: try XCTUnwrap(image.cgImage),
            position: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1),
            canvasSize: videoSize
        )
        overlay.update(
            cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .image(bitmap))],
            sourceTime: 5, videoSize: videoSize
        )
        overlay.layoutIfNeeded()
        let imageView = try XCTUnwrap(overlay.subviews.first as? UIImageView)
        XCTAssertNotNil(imageView.image)
        XCTAssertEqual(imageView.frame.minY, 864, accuracy: 0.001)
        XCTAssertEqual(imageView.frame.width, 960, accuracy: 0.001)
        overlay.update(cues: [], sourceTime: 5, videoSize: videoSize)
        XCTAssertTrue(overlay.subviews.isEmpty)
    }

    private let videoSize = CGSize(width: 1920, height: 1080)

    @MainActor
    private func makeOverlay() -> HybridSubtitleOverlayView {
        let overlay = HybridSubtitleOverlayView()
        overlay.frame = CGRect(origin: .zero, size: videoSize)
        return overlay
    }
}
#endif
