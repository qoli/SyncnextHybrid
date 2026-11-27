#if os(tvOS)
@preconcurrency import AVFoundation
import UIKit

/// Mirrors selected native HLS text above the host's interpolated picture.
/// The passive output leaves AVPlayer's captions and media selection intact.
@MainActor
final class HybridNativeSubtitleOverlay: UIView, AVPlayerItemLegibleOutputPushDelegate {
    private let label = UILabel()
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private weak var picture: UIView?
    private var itemObservation: NSKeyValueObservation?
    private var output: AVPlayerItemLegibleOutput?
    private(set) var text = ""
    private(set) var itemTime: Double?
    private(set) var deliveries = 0
    private(set) var flushes = 0

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityIdentifier = "SyncnextHybrid.NativeSubtitleOverlay"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.accessibilityIdentifier = "SyncnextHybrid.NativeSubtitleText"
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.68
        label.layer.shadowOffset = CGSize(width: 0, height: 6)
        label.layer.shadowRadius = 12
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(to player: AVPlayer?) {
        guard self.player !== player else { return }
        detach()
        self.player = player
        itemObservation = player?.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, self.player === player else { return }
                self.attach(to: player?.currentItem)
            }
        }
    }

    func mount(above picture: UIView, in overlay: UIView) {
        self.picture = picture
        frame = overlay.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.insertSubview(self, aboveSubview: picture)
        updateVisibility()
        setNeedsLayout()
    }

    func unmount() {
        picture = nil
        removeFromSuperview()
    }

    func detach() {
        itemObservation?.invalidate()
        itemObservation = nil
        removeOutput()
        player = nil
        unmount()
    }

    var isAbovePicture: Bool {
        guard let parent = superview, let picture, picture.superview === parent,
              let pictureIndex = parent.subviews.firstIndex(of: picture),
              let captionIndex = parent.subviews.firstIndex(of: self) else { return false }
        return captionIndex > pictureIndex
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let videoRect = HybridSubtitlePresentation.videoRect(in: bounds, videoSize: item?.presentationSize ?? .zero)
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: videoRect.height * 0.045, weight: .medium),
            .foregroundColor: UIColor.white,
        ])
        let size = label.sizeThatFits(CGSize(width: videoRect.width * 0.9, height: .greatestFiniteMagnitude))
        label.frame = HybridSubtitlePresentation.textRect(size: size, placement: nil, videoRect: videoRect, bottomOffset: 0)
    }

    private func attach(to item: AVPlayerItem?) {
        guard self.item !== item else { return }
        removeOutput()
        self.item = item
        guard let item else { return }
        let output = AVPlayerItemLegibleOutput()
        // Never begin suppressing a line already rendered by AVPlayer. The
        // opaque interpolation picture covers it; this mirror sits above it.
        output.suppressesPlayerRendering = false
        output.advanceIntervalForDelegateInvocation = 0
        output.setDelegate(self, queue: .main)
        self.output = output
        item.add(output)
    }

    private func removeOutput() {
        output?.setDelegate(nil, queue: nil)
        if let output { item?.remove(output) }
        output = nil
        item = nil
        text = ""
        itemTime = nil
        updateVisibility()
    }

    private func updateVisibility() {
        isHidden = text.isEmpty || !isAbovePicture
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                   didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n")
        MainActor.assumeIsolated {
            guard self.output === output else { return }
            self.text = text
            self.itemTime = itemTime.seconds
            self.deliveries += 1
            self.updateVisibility()
            self.setNeedsLayout()
        }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated {
            guard self.output === output else { return }
            self.text = ""
            self.itemTime = nil
            self.flushes += 1
            self.updateVisibility()
            self.setNeedsLayout()
        }
    }
}
#endif
