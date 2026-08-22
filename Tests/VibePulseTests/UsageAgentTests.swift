import XCTest

@testable import VibePulse

final class UsageAgentTests: XCTestCase {
  func testArbitraryAgentPreservesExactIdentifierInDailyCommand() {
    let agent = UsageAgent("future-agent_v2")
    let timeZone = TimeZone(identifier: "America/New_York")!

    XCTAssertEqual(agent.rawValue, "future-agent_v2")
    XCTAssertEqual(
      agent.dailyCommand(in: timeZone),
      [
        "agentsview", "usage", "daily", "--format", "json", "--breakdown", "--agent",
        "future-agent_v2", "--since", "30d", "--timezone", "America/New_York", "--no-sync",
      ])
  }

  func testDiscoveryCommandRequestsAgentBreakdownsForThirtyDays() {
    let timeZone = TimeZone(identifier: "America/New_York")!

    XCTAssertEqual(
      UsageAgent.discoveryCommand(in: timeZone),
      [
        "agentsview", "usage", "daily", "--format", "json", "--breakdown", "--since",
        "30d", "--timezone", "America/New_York",
      ])
  }

  func testKnownAndGeneratedDisplayNamesArePresentationOnly() {
    XCTAssertEqual(UsageAgent.claude.displayName, "Claude Code")
    XCTAssertEqual(UsageAgent.omp.displayName, "OhMyPi")
    XCTAssertEqual(UsageAgent.copilot.displayName, "GitHub Copilot")
    XCTAssertEqual(UsageAgent("future-agent").displayName, "Future Agent")
  }

  func testCopilotAgentUsesCopilotIdentifier() {
    XCTAssertEqual(UsageAgent.copilot.rawValue, "copilot")
  }

  func testAgentsSortByDisplayNameThenRawIdentifier() {
    let agents = [UsageAgent("zeta"), .claude, UsageAgent("alpha")]

    XCTAssertEqual(agents.sorted().map(\.rawValue), ["alpha", "claude", "zeta"])
  }

  func testChartIdentityDoesNotCollapseAgentsWithTheSameGeneratedLabel() {
    let hyphenated = UsageSeriesKey.agent(UsageAgent("future-agent"))
    let underscored = UsageSeriesKey.agent(UsageAgent("future_agent"))

    XCTAssertEqual(hyphenated.displayName, underscored.displayName)
    XCTAssertNotEqual(hyphenated.chartIdentity, underscored.chartIdentity)
  }
}
