import SwiftUI

@main
struct HybridSmokePlayerApp: App {
    @StateObject private var model = SmokeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    model.startFromEnvironmentIfPresent()
                }
        }
    }
}
