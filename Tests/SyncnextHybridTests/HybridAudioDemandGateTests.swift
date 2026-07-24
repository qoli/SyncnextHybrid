import XCTest
@testable import SyncnextHybrid

final class HybridAudioDemandGateTests: XCTestCase {
    func testSecondConsumerFailsExplicitly() async throws {
        let gate = HybridAudioDemandGate()
        let firstConsumer = UUID()
        let firstWaiter = Task {
            try await gate.next(consumerID: firstConsumer)
        }

        await Task.yield()

        do {
            _ = try await gate.next(consumerID: UUID())
            XCTFail("second consumer unexpectedly acquired the stream")
        } catch let error as HybridAudioAnalysisError {
            XCTAssertEqual(error, .concurrentConsumer)
        }

        await gate.cancel()
        _ = try? await firstWaiter.value
    }

    func testCancelTerminatesWaitingProducerAndConsumer() async {
        let gate = HybridAudioDemandGate()
        let producer = Task {
            try await gate.waitForDemand()
        }
        await Task.yield()
        await gate.cancel()

        do {
            _ = try await producer.value
            XCTFail("cancelled producer unexpectedly resumed successfully")
        } catch let error as HybridAudioAnalysisError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        do {
            _ = try await gate.next(consumerID: UUID())
            XCTFail("cancelled stream unexpectedly produced a value")
        } catch let error as HybridAudioAnalysisError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected consumer error: \(error)")
        }
    }
}
