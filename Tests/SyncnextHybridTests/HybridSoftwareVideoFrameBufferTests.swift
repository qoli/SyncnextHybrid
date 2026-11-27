import AetherEngine
import CoreMedia
import CoreVideo
import XCTest
@testable import SyncnextHybrid

final class HybridSoftwareVideoFrameBufferTests: XCTestCase {
    private func frame(_ seconds: Double, generation: UInt64 = 1) -> SoftwareVideoFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        return SoftwareVideoFrame(pixelBuffer: buffer!, presentation: time(seconds), generation: generation)
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    func testClockPrunesExpiredPicturesAndRetainsRendererLookahead() {
        let buffer = HybridSoftwareVideoFrameBuffer()
        for second in 0..<100 {
            buffer.receive(frame(Double(second)), clock: time(Double(second) - 0.5))
        }
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.picture(at: time(98.5), clock: time(98.5))?.presentation.seconds, 98)
        XCTAssertEqual(buffer.picture(at: time(99), clock: time(98.5))?.presentation.seconds, 99)
        XCTAssertNil(buffer.picture(at: time(97), clock: time(98.5)))
    }

    func testBackwardSeekRejectsLatePicturesFromTheDiscardedGeneration() {
        let buffer = HybridSoftwareVideoFrameBuffer()
        buffer.receive(frame(90, generation: 4), clock: time(89))
        let before = buffer.revision
        buffer.awaitNextGeneration()
        XCTAssertNil(buffer.picture(at: time(100), clock: time(2)))
        buffer.receive(frame(91, generation: 4), clock: time(2))
        XCTAssertEqual(buffer.count, 0)
        buffer.receive(frame(2, generation: 7), clock: time(2))
        buffer.receive(frame(92, generation: 4), clock: time(2))
        XCTAssertEqual(buffer.picture(at: time(2), clock: time(2))?.generation, 7)
        XCTAssertGreaterThan(buffer.revision, before)
    }

    func testRetainsTheOriginalPixelBufferWithoutCopyingOrChangingItsTimestamp() {
        let buffer = HybridSoftwareVideoFrameBuffer()
        let original = frame(42, generation: 3)
        buffer.receive(original, clock: time(41))
        let captured = buffer.picture(at: time(42), clock: time(41))
        XCTAssertTrue(captured?.pixelBuffer === original.pixelBuffer)
        XCTAssertEqual(captured?.presentation, original.presentation)
        XCTAssertEqual(captured?.generation, original.generation)
    }

    func testStopReleasesPicturesAndRejectsLateCallbacks() {
        let buffer = HybridSoftwareVideoFrameBuffer()
        buffer.receive(frame(1), clock: time(0))
        buffer.stop()
        buffer.receive(frame(2, generation: 2), clock: time(0))
        XCTAssertEqual(buffer.count, 0)
        XCTAssertNil(buffer.picture(at: time(10), clock: time(0)))
    }
}
