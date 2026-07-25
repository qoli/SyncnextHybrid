import AVKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SmokeViewModel

    var body: some View {
        Group {
            if model.hasAttachedSession {
                player
            } else {
                setup
            }
        }
        .background(Color.black)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("SyncnextHybrid tvOS Smoke")
                .font(.largeTitle.bold())

            Text(
                "Tests the public Hybrid interface through native AVKit. "
                    + "No source, route, or player fallback is used."
            )
            .foregroundStyle(.secondary)

            TextField("Absolute media URL", text: $model.sourceURLText)
                .textContentType(.URL)
                .accessibilityIdentifier("hybrid-smoke-url")

            TextField(
                "Optional HTTP headers JSON",
                text: $model.headersJSONText
            )
            .accessibilityIdentifier("hybrid-smoke-headers")

            TextField(
                "Seek target in seconds",
                text: $model.seekSecondsText
            )
            .accessibilityIdentifier("hybrid-smoke-seek")

            HStack(spacing: 24) {
                Button("Run Smoke") {
                    model.runInteractive()
                }
                .accessibilityIdentifier("hybrid-smoke-run")

                if model.runState == .loading {
                    ProgressView()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.runState.title)
                    .font(.headline)
                Text(model.statusMessage)
                    .foregroundStyle(
                        model.runState == .failed
                            ? Color.red
                            : Color.secondary
                    )
                    .accessibilityIdentifier("hybrid-smoke-status")
            }

            Text(
                "Fixed smoke contract: ≤30s paused VOD readiness, "
                    + "+2s startup progress, pause, exact seek, "
                    + "+2s post-seek progress, 60.5s "
                    + "zero-progress limit."
            )
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(64)
    }

    private var player: some View {
        ZStack(alignment: .topLeading) {
            PlayerControllerView(
                controller: model.playerViewController
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 6) {
                Text(model.runState.title)
                    .font(.headline.bold())
                    .foregroundStyle(statusColor)
                Text(model.sourceDisplay)
                Text(
                    "\(model.routeName) · \(model.phaseName) · "
                        + "\(format(model.currentTime)) / "
                        + "\(format(model.duration))"
                )
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)

                if model.runState == .passed
                    || model.runState == .failed {
                    Button("Reset") {
                        model.reset()
                    }
                    .padding(.top, 8)
                    .accessibilityIdentifier("hybrid-smoke-reset")
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(20)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 14))
            .padding(36)
            .accessibilityIdentifier("hybrid-smoke-overlay")
        }
        .onExitCommand {
            model.reset()
        }
    }

    private var statusColor: Color {
        switch model.runState {
        case .passed:
            .green
        case .failed:
            .red
        default:
            .white
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "--:--"
        }
        let bounded = max(0, Int(seconds))
        return String(
            format: "%02d:%02d:%02d",
            bounded / 3600,
            (bounded / 60) % 60,
            bounded % 60
        )
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    let controller: AVPlayerViewController

    func makeUIViewController(
        context: Context
    ) -> AVPlayerViewController {
        controller
    }

    func updateUIViewController(
        _ uiViewController: AVPlayerViewController,
        context: Context
    ) {}
}
