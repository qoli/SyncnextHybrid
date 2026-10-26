import AetherEngine
import XCTest
@testable import SyncnextHybrid

final class HybridOptionalComponentsTests: XCTestCase {
    func testAllFourComponentsAreCompiled() {
        XCTAssertEqual(HybridOptionalComponent.allCases.count, 4)
        for component in HybridOptionalComponent.allCases {
            XCTAssertTrue(component.isBuiltIn, component.traitName)
        }
    }

    func testDefaultRequestPreservesExistingPlaybackOptions() throws {
        let request = try HybridPlaybackRequest(url: URL(string: "https://example.com/movie.mkv")!)
        let plan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: [],
            admission: .aetherDefault(.confirmedFiniteEBML)
        )
        XCTAssertEqual(plan.options.objectAudioRendering, .off)
        XCTAssertFalse(plan.options.preferDualLayerDolbyVision)
    }

    func testExplicitOptionsReachAetherAcrossAdmissionPaths() throws {
        let request = try HybridPlaybackRequest(
            url: URL(string: "https://example.com/movie.mkv")!,
            objectAudioRendering: .apac(.l714),
            preferDualLayerDolbyVision: true
        )
        for admission: HybridRemoteSourceAdmission in [
            .aetherDefault(.confirmedFiniteEBML),
            .hlsVOD,
            .hlsVODHEVCMPEGTS(duration: 60, evidence: .standardStreamType(0x24)),
            .hlsLive,
        ] {
            let plan = HybridPlaybackPlan.make(request: request, externalSubtitles: [], admission: admission)
            XCTAssertEqual(plan.options.objectAudioRendering, .apac(.l714))
            XCTAssertTrue(plan.options.preferDualLayerDolbyVision)
            XCTAssertEqual(plan.url, request.url)
        }
    }
}
