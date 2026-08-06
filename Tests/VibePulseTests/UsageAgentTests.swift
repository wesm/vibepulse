import XCTest

@testable import VibePulse

final class UsageAgentTests: XCTestCase {
  func testArbitraryAgentPreservesExactIdentifierInDailyCommand() {
    let agent = UsageAgent("future-agent_v2")

    XCTAssertEqual(agent.rawValue, "future-agent_v2")
    XCTAssertEqual(
      agent.dailyCommand,
      [
        "agentsview", "usage", "daily", "--format", "json", "--breakdown", "--agent",
        "future-agent_v2", "--since", "30d", "--no-sync",
      ])
  }

  func testDiscoveryCommandRequestsAgentBreakdownsForThirtyDays() {
    XCTAssertEqual(
      UsageAgent.discoveryCommand,
      [
        "agentsview", "usage", "daily", "--format", "json", "--breakdown", "--since",
        "30d",
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
