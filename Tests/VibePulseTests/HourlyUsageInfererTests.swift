import XCTest
@testable import VibePulse

final class HourlyUsageInfererTests: XCTestCase {
    func testHourlyDistributionAcrossHours() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let sample1Time = calendar.date(byAdding: .hour, value: 1, to: start)!
        let sample2Time = calendar.date(byAdding: .hour, value: 3, to: start)!
        let end = calendar.date(byAdding: .minute, value: 30, to: sample2Time)!

        let samples = [
            UsageSample(tool: .claude, recordedAt: sample1Time, totalCost: 10, deltaCost: 10),
            UsageSample(tool: .claude, recordedAt: sample2Time, totalCost: 30, deltaCost: 20),
        ]

        let points = HourlyUsageInferer.inferPoints(tool: .claude, samples: samples, startOfDay: start, end: end)
        var byHour: [Int: Double] = [:]
        for point in points {
            let hour = calendar.component(.hour, from: point.date)
            byHour[hour] = point.cost
        }

        XCTAssertEqual(try XCTUnwrap(byHour[0]), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byHour[1]), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byHour[2]), 10, accuracy: 0.001)
    }
}
