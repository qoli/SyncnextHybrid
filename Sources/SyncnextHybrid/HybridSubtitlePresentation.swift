import AetherEngine
import CoreGraphics
import Foundation

/// Subtitle cues use source PTS, which can differ from the AVKit timeline.
enum HybridSubtitlePresentation {
    static func activeCues(
        _ cues: [SubtitleCue],
        sourceTime: Double
    ) -> [SubtitleCue] {
        guard sourceTime.isFinite else { return [] }
        return cues.filter {
            $0.startTime <= sourceTime && sourceTime < $0.endTime
        }
    }

    static func videoRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else {
            return bounds
        }
        let scale = min(
            bounds.width / videoSize.width,
            bounds.height / videoSize.height
        )
        let size = CGSize(
            width: videoSize.width * scale,
            height: videoSize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func imageRect(
        position: CGRect,
        canvasSize: CGSize,
        videoRect: CGRect
    ) -> CGRect {
        let canvas = canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize : videoRect.size
        let scale = videoRect.width / canvas.width
        return CGRect(
            x: videoRect.minX + position.minX * canvas.width * scale,
            y: videoRect.midY
                + (position.minY - 0.5) * canvas.height * scale,
            width: position.width * canvas.width * scale,
            height: position.height * canvas.height * scale
        )
    }

    static func textRect(
        size: CGSize,
        placement: SubtitleTextPlacement?,
        videoRect: CGRect,
        bottomOffset: CGFloat
    ) -> CGRect {
        let alignment = placement?.alignment ?? 2
        let column = (alignment - 1) % 3
        let row = (alignment - 1) / 3
        let horizontalInset = videoRect.width * 0.05
        let verticalInset = videoRect.height * 0.05
        let anchor: CGPoint
        if let position = placement?.position {
            anchor = CGPoint(
                x: videoRect.minX + position.x * videoRect.width,
                y: videoRect.minY + position.y * videoRect.height
            )
        } else {
            anchor = CGPoint(
                x: column == 0 ? videoRect.minX + horizontalInset
                    : column == 2 ? videoRect.maxX - horizontalInset
                    : videoRect.midX,
                y: row == 2 ? videoRect.minY + verticalInset
                    : row == 1 ? videoRect.midY
                    : videoRect.maxY - verticalInset - bottomOffset
            )
        }
        return CGRect(
            x: anchor.x - CGFloat(column) * size.width / 2,
            y: anchor.y - (row == 2 ? 0 : row == 1 ? size.height / 2 : size.height),
            width: size.width,
            height: size.height
        )
    }
}
