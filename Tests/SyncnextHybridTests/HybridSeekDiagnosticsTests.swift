#if DEBUG
import XCTest
@testable import SyncnextHybrid

final class HybridSeekDiagnosticsTests: XCTestCase {
    func testExistingProducerBoundaryIsRetained() {
        let line = "[HLSVideoEngine] producer restarted at idx=29 (restart took 20ms; stopWait=19ms seek=0ms build=1ms)"
        XCTAssertEqual(HybridSeekDiagnosticObservation.safeMessage(line), line)
    }

    func testNativeLoaderFailureDoesNotForwardItsMediaURI() {
        let line = "[NativeAVPlayerHost] #1 errorLog code=-12889 domain=CoreMediaErrorDomain uri=https://fixture.invalid/media?token=fixture-secret 'No response'"
        XCTAssertEqual(HybridSeekDiagnosticObservation.safeMessage(line),
                       "[NativeAVPlayerHost] errorLog code=-12889")
    }

    func testSourceURLsAndUnrelatedDiagnosticsAreNotForwarded() {
        XCTAssertNil(HybridSeekDiagnosticObservation.safeMessage("[AetherEngine] load url=https://fixture.invalid/media"))
        XCTAssertNil(HybridSeekDiagnosticObservation.safeMessage("[HLSVideoEngine] producer restarted https://fixture.invalid/media"))
        XCTAssertNil(HybridSeekDiagnosticObservation.safeMessage("[AudioBridge] decoded packet"))
    }
}
#endif
