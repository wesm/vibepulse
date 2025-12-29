import XCTest
@testable import VibePulse

final class UsageStoreTests: XCTestCase {
    func testSampleDeltaCalculation() throws {
        let store = try UsageStore(path: ":memory:")
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let first = calendar.date(byAdding: .minute, value: 5, to: start)!
        let second = calendar.date(byAdding: .minute, value: 30, to: start)!

        try store.insertSample(tool: .claude, totalCost: 10, recordedAt: first)
        try store.insertSample(tool: .claude, totalCost: 15, recordedAt: second)

        let samples = store.fetchSamples(tool: .claude, from: start, to: second)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].deltaCost, 10, accuracy: 0.001)
        XCTAssertEqual(samples[1].deltaCost, 5, accuracy: 0.001)
    }

    func testSampleDeltaDoesNotGoNegative() throws {
        let store = try UsageStore(path: ":memory:")
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 16))!
        let first = calendar.date(byAdding: .minute, value: 10, to: start)!
        let second = calendar.date(byAdding: .minute, value: 20, to: start)!

        try store.insertSample(tool: .codex, totalCost: 12, recordedAt: first)
        try store.insertSample(tool: .codex, totalCost: 8, recordedAt: second)

        let samples = store.fetchSamples(tool: .codex, from: start, to: second)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].deltaCost, 12, accuracy: 0.001)
        XCTAssertEqual(samples[1].deltaCost, 0, accuracy: 0.001)
    }
}
