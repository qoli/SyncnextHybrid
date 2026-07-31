#if os(tvOS)
import Foundation

enum ProxyMediaFactory {
    @MainActor
    static func makeTimeline(
        duration: Double,
        initialPosition: Double,
        initialBufferedThrough: Double
    ) async throws -> HybridHLSTimelineProxy {
        try await HybridHLSTimelineProxy(
            duration: duration,
            initialPosition: initialPosition,
            initialBufferedThrough: initialBufferedThrough
        )
    }
}
#endif
