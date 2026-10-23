#if DEBUG
import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridVODRangeTelemetryTests: XCTestCase {
    func testOverlapIntegratesTransitionsBetweenSamplesAndDrainDoesNotResetTotals() throws {
        var meter = HybridVODRangeTestTelemetry(role: "primary", origin: 0)
        meter.start(id: 1, metadata: false, lower: 0, upper: 4, blocks: 1, buffered: 0, at: 1)
        meter.start(id: 2, metadata: false, lower: 4, upper: 8, blocks: 2, buffered: 0, at: 2)
        meter.headers(id: 1, status: 206, accepted: true, at: 3)
        meter.headers(id: 2, status: 206, accepted: true, at: 4)
        meter.data(id: 1, bytes: 2, at: 5)
        meter.data(id: 1, bytes: 2, at: 8)
        let first = try XCTUnwrap(meter.drain(at: 8.5))
        XCTAssertEqual(first.requests.count, 2, "Multiple callbacks coalesce per request")
        meter.finish(id: 1, outcome: "completed", at: 9)
        meter.finish(id: 2, outcome: "completed", at: 10)
        let activity = meter.activity(at: 13)
        XCTAssertEqual(activity.singleTaskSeconds, 2)
        XCTAssertEqual(activity.dualTaskSeconds, 7)
        XCTAssertEqual(activity.singleResponseSeconds, 2)
        XCTAssertEqual(activity.dualResponseSeconds, 5)
        let second = try XCTUnwrap(meter.drain(at: 13))
        let spans = first.activity + second.activity
        XCTAssertEqual(spans.reduce(0) { $0 + $1.end - $1.start }, 13)
        let request = try XCTUnwrap(second.requests.first { $0.taskID == 1 })
        XCTAssertEqual(request.firstBodyAt, 5)
        XCTAssertEqual(request.maximumBodyGapSeconds, 3)
        XCTAssertEqual(request.finishedAt, 9)
        XCTAssertNil(request.transactions, "Unavailable metrics must not become zero")
    }

    func testCancelledRequestRetainsLateMetricsAndDataAcrossSeekEpoch() throws {
        var meter = HybridVODRangeTestTelemetry(role: "primary", origin: 100)
        meter.start(id: 1, metadata: false, lower: 0, upper: 4, blocks: 1, buffered: 0, at: 101)
        meter.headers(id: 1, status: 206, accepted: true, at: 102)
        meter.finish(id: 1, outcome: "cancelled", reason: "seek", at: 103)
        _ = meter.drain(at: 103)
        meter.nextEpoch()
        meter.start(id: 2, metadata: false, lower: 10, upper: 14, blocks: 1, buffered: 0, at: 104)
        meter.data(id: 1, bytes: 2, at: 105)
        meter.metrics(id: 1, transactions: [])
        meter.finish(id: 1, outcome: "failed", at: 106) // late completion cannot overwrite cancellation
        let batch = try XCTUnwrap(meter.drain(at: 107))
        let old = try XCTUnwrap(batch.requests.first { $0.taskID == 1 })
        let new = try XCTUnwrap(batch.requests.first { $0.taskID == 2 })
        XCTAssertEqual(old.outcome, "cancelled")
        XCTAssertEqual(old.cancellationReason, "seek")
        XCTAssertEqual(old.finishedAt, 3)
        XCTAssertEqual(old.lateBytes, 2)
        XCTAssertEqual(old.transactions?.count, 0)
        XCTAssertEqual(new.epoch, old.epoch + 1)
        XCTAssertNil(new.firstBodyAt)
        XCTAssertEqual(meter.activity(at: 107).dualTaskSeconds, 0)
        let encoded = try JSONEncoder().encode(batch)
        XCTAssertNoThrow(try JSONDecoder().decode(HybridVODRangeTraceBatch.self, from: encoded))
    }
}
#endif
