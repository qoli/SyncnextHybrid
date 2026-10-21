import AetherEngine
import UIKit

@main
@MainActor
final class SubtitleStyleProbeApp: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }
}

@MainActor
final class SubtitleStyleProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = SubtitleStyleProbeController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@MainActor
final class SubtitleStyleProbeController: UIViewController {
    private let background = ProbeBackgroundView()
    private let overlay = HybridSubtitleOverlayView()
    private let sample = "好吧 面试时我汗流浃背\n可现在 我被斯坦福大学录取了"

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(background)

        let heading = makeLabel("字幕樣式 Probe", size: 38, weight: .bold)
        heading.frame = CGRect(x: 80, y: 45, width: 1100, height: 60)
        view.addSubview(heading)
        let help = makeLabel("固定文字 · 無網路／播放流程 · 遙控器左右切換背景", size: 24)
        help.frame = CGRect(x: 80, y: 110, width: 1700, height: 40)
        view.addSubview(help)

        addReference(
            title: "A · 原單次描邊（重現問題）",
            y: 210,
            strokeWidth: -2.0
        )
        addReference(title: "B · 實心白字＋黑色陰影（0.68 · y 6 · r 12）", y: 475, strokeWidth: nil)
        let production = makeLabel("C · 正式 renderer：已採用 B ＋指定陰影", size: 24)
        production.frame = CGRect(x: 80, y: 735, width: 1700, height: 40)
        view.addSubview(production)
        view.addSubview(overlay)
        overlay.update(
            cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text(sample))],
            sourceTime: 5,
            videoSize: CGSize(width: 1920, height: 800)
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        background.frame = view.bounds
        overlay.frame = view.bounds
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
            background.advance()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    private func addReference(title: String, y: CGFloat, strokeWidth: Double?) {
        let caption = makeLabel(title, size: 24)
        caption.frame = CGRect(x: 80, y: y, width: 1700, height: 40)
        view.addSubview(caption)
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 36, weight: .medium),
            .foregroundColor: UIColor.white,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributes[.paragraphStyle] = paragraph
        if let strokeWidth {
            attributes[.strokeWidth] = strokeWidth
            attributes[.strokeColor] = UIColor.black
        } else {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.68
            label.layer.shadowOffset = CGSize(width: 0, height: 6)
            label.layer.shadowRadius = 12
            label.layer.masksToBounds = false
        }
        label.attributedText = NSAttributedString(string: sample, attributes: attributes)
        label.accessibilityIdentifier = strokeWidth == nil ? "Probe.PlainFill" : "Probe.SinglePassStroke"
        label.frame = CGRect(x: 100, y: y + 55, width: 1720, height: 100)
        view.addSubview(label)
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: UIFont.Weight = .regular
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        return label
    }
}

@MainActor
final class ProbeBackgroundView: UIView {
    private var mode = 0

    func advance() {
        mode = (mode + 1) % 3
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if mode == 1 || mode == 2 {
            (mode == 1 ? UIColor.black : UIColor(white: 0.9, alpha: 1)).setFill()
            context.fill(bounds)
            return
        }
        let colors: [UIColor] = [.init(white: 0.85, alpha: 1), .init(white: 0.4, alpha: 1), .black]
        for (index, color) in colors.enumerated() {
            color.setFill()
            context.fill(CGRect(
                x: CGFloat(index) * bounds.width / 3,
                y: 0, width: bounds.width / 3, height: bounds.height
            ))
        }
    }
}
