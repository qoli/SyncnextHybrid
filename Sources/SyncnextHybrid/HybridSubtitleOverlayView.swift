#if os(tvOS)
import AetherEngine
import UIKit

/// Transparent host rendering for Aether's decoded text and bitmap cues.
/// It is separate from AetherPlayerView, which owns only the video layer.
@MainActor
final class HybridSubtitleOverlayView: UIView {
    private var activeCues: [SubtitleCue] = []
    private var videoSize: CGSize = .zero
    private var cueViews: [UIView] = []

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = "SyncnextHybrid.SubtitleOverlay"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        cues: [SubtitleCue],
        sourceTime: Double,
        videoSize: CGSize,
        cuesChanged: Bool = false
    ) {
        if self.videoSize != videoSize {
            self.videoSize = videoSize
            setNeedsLayout()
        }
        let active = HybridSubtitlePresentation.activeCues(
            cues,
            sourceTime: sourceTime
        )
        guard cuesChanged || active != activeCues else { return }
        activeCues = active
        cueViews.forEach { $0.removeFromSuperview() }
        cueViews = active.map { cue in
            let view: UIView
            switch cue.body {
            case .text, .richText:
                let label = UILabel()
                label.numberOfLines = 0
                label.accessibilityIdentifier = "SyncnextHybrid.SubtitleText"
                label.layer.shadowColor = UIColor.black.cgColor
                label.layer.shadowOpacity = 0.68
                label.layer.shadowOffset = CGSize(width: 0, height: 6)
                label.layer.shadowRadius = 12
                label.layer.masksToBounds = false
                view = label
            case .image(let image):
                let imageView = UIImageView(image: UIImage(cgImage: image.cgImage))
                imageView.accessibilityIdentifier = "SyncnextHybrid.SubtitleImage"
                view = imageView
            }
            view.isUserInteractionEnabled = false
            addSubview(view)
            return view
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let videoRect = HybridSubtitlePresentation.videoRect(
            in: bounds,
            videoSize: videoSize
        )
        guard videoRect.width > 0, videoRect.height > 0 else { return }
        var bottomOffset: CGFloat = 0
        for (cue, view) in zip(activeCues, cueViews) {
            switch cue.body {
            case .image(let image):
                view.frame = HybridSubtitlePresentation.imageRect(
                    position: image.position,
                    canvasSize: image.canvasSize,
                    videoRect: videoRect
                )
            case .text, .richText:
                guard let label = view as? UILabel else { continue }
                label.attributedText = attributedText(
                    for: cue,
                    fontSize: videoRect.height * 0.045
                )
                let size = label.sizeThatFits(CGSize(
                    width: videoRect.width * 0.9,
                    height: .greatestFiniteMagnitude
                ))
                label.frame = HybridSubtitlePresentation.textRect(
                    size: size,
                    placement: cue.placement,
                    videoRect: videoRect,
                    bottomOffset: bottomOffset
                )
                if cue.placement == nil {
                    bottomOffset += size.height
                }
            }
        }
    }

    private func attributedText(
        for cue: SubtitleCue,
        fontSize: CGFloat
    ) -> NSAttributedString {
        let runs: [SubtitleTextRun]
        switch cue.body {
        case .text(let text):
            runs = [SubtitleTextRun(text: text, color: nil)]
        case .richText(let textRuns):
            runs = textRuns
        case .image:
            return NSAttributedString()
        }
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        switch (cue.placement?.alignment ?? 2) % 3 {
        case 1: paragraph.alignment = .left
        case 0: paragraph.alignment = .right
        default: paragraph.alignment = .center
        }
        for run in runs {
            var font = UIFont.systemFont(
                ofSize: fontSize,
                weight: run.isBold ? .bold : .medium
            )
            if run.isItalic,
               let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitItalic)
               ) {
                font = UIFont(descriptor: descriptor, size: fontSize)
            }
            let color = run.color.map {
                UIColor(
                    red: CGFloat($0.r) / 255,
                    green: CGFloat($0.g) / 255,
                    blue: CGFloat($0.b) / 255,
                    alpha: 1
                )
            } ?? .white
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if run.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.isStruckThrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}

#endif
