import XCTest

@testable import VibePulse

final class UsageToolTests: XCTestCase {
  func testSupportedToolsIncludeAgentsviewPricingSources() {
    XCTAssertEqual(
      UsageTool.allCases.map(\.rawValue),
      ["claude", "codex", "pi", "opencode"])
  }

  func testDailyCommandsFilterAgentsviewByToolAgentName() {
    XCTAssertEqual(
      UsageTool.pi.dailyCommand,
      ["agentsview", "usage", "daily", "--json", "--agent", "pi"])
    XCTAssertEqual(
      UsageTool.openCode.dailyCommand,
      ["agentsview", "usage", "daily", "--json", "--agent", "opencode"])
  }
}
