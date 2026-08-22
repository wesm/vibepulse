import XCTest

@testable import VibePulse

final class UsageRefreshServiceTests: XCTestCase {
  func testRefreshImportsEveryDiscoveredAgent() throws {
    let first = UsageAgent("future-agent")
    let second = UsageAgent("other-agent")
    let fetcher = StubUsageFetcher(
      discoveredAgents: [first, second],
      totalsByAgent: [
        first: [DailyTotal(dateKey: "2026-07-17", cost: 2)],
        second: [DailyTotal(dateKey: "2026-07-17", cost: 3)],
      ])
    let store = try UsageStore(path: ":memory:")
    let service = UsageRefreshService(fetcher: fetcher, store: store)
    let context = testContext()

    let result = try service.refresh(context: context)

    XCTAssertEqual(result.discoveredAgents, [first, second].sorted())
    XCTAssertEqual(fetcher.requestedAgents, [first, second])
    XCTAssertEqual(store.dailyTotal(for: "2026-07-17", tool: first), 2)
    XCTAssertEqual(store.dailyTotal(for: "2026-07-17", tool: second), 3)
    XCTAssertEqual(result.importErrors, [])
  }

  func testRefreshContinuesAfterOneAgentImportFails() throws {
    let failed = UsageAgent("failed-agent")
    let successful = UsageAgent("successful-agent")
    let fetcher = StubUsageFetcher(
      discoveredAgents: [failed, successful],
      totalsByAgent: [successful: [DailyTotal(dateKey: "2026-07-17", cost: 3)]],
      failingAgents: [failed])
    let store = try UsageStore(path: ":memory:")
    let service = UsageRefreshService(fetcher: fetcher, store: store)
    let context = testContext()

    let result = try service.refresh(context: context)

    XCTAssertEqual(fetcher.requestedAgents, [failed, successful])
    XCTAssertEqual(store.dailyTotal(for: "2026-07-17", tool: successful), 3)
    XCTAssertEqual(result.importErrors.count, 1)
    XCTAssertTrue(result.importErrors[0].hasPrefix("Failed Agent:"))
  }

  func testDiscoveryFailurePreventsImports() throws {
    let fetcher = StubUsageFetcher(discoveryError: StubError.discoveryFailed)
    let store = try UsageStore(path: ":memory:")
    let service = UsageRefreshService(fetcher: fetcher, store: store)

    XCTAssertThrowsError(
      try service.refresh(context: testContext()))
    XCTAssertEqual(fetcher.requestedAgents, [])
  }

  func testRefreshInvalidatesCurrentDayBeforeImportingNewTotals() throws {
    let agent = UsageAgent("future-agent")
    let context = testContext()
    let fetcher = StubUsageFetcher(
      discoveredAgents: [agent],
      totalsByAgent: [agent: [DailyTotal(dateKey: context.todayKey, cost: 7)]])
    let store = try UsageStore(path: ":memory:")
    try store.insertSample(
      tool: agent,
      totalCost: 100,
      recordedAt: context.now,
      dateContext: UsageDateContext(
        now: context.now,
        timeZone: TimeZone(identifier: "UTC")!))
    let service = UsageRefreshService(fetcher: fetcher, store: store)

    _ = try service.refresh(context: context, invalidateCurrentDay: true)

    let samples = store.fetchSamples(
      tool: agent, from: context.startOfToday, to: context.now)
    XCTAssertEqual(samples.map(\.totalCost), [7])
  }

  private func testContext() -> UsageDateContext {
    UsageDateContext(
      now: ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!,
      timeZone: TimeZone(identifier: "UTC")!)
  }
}

private enum StubError: LocalizedError {
  case discoveryFailed
  case importFailed

  var errorDescription: String? {
    switch self {
    case .discoveryFailed: return "discovery failed"
    case .importFailed: return "import failed"
    }
  }
}

private final class StubUsageFetcher: UsageFetching, @unchecked Sendable {
  private let discoveredAgents: [UsageAgent]
  private let totalsByAgent: [UsageAgent: [DailyTotal]]
  private let failingAgents: Set<UsageAgent>
  private let discoveryError: Error?
  private(set) var requestedAgents: [UsageAgent] = []
  private(set) var requestedTimeZones: [String] = []

  init(
    discoveredAgents: [UsageAgent] = [],
    totalsByAgent: [UsageAgent: [DailyTotal]] = [:],
    failingAgents: Set<UsageAgent> = [],
    discoveryError: Error? = nil
  ) {
    self.discoveredAgents = discoveredAgents
    self.totalsByAgent = totalsByAgent
    self.failingAgents = failingAgents
    self.discoveryError = discoveryError
  }

  func discoverAgents(using context: UsageDateContext) throws -> [UsageAgent] {
    requestedTimeZones.append(context.timeZone.identifier)
    if let discoveryError { throw discoveryError }
    return discoveredAgents
  }

  func fetchDailyTotals(for tool: UsageAgent, using context: UsageDateContext) throws
    -> [DailyTotal]
  {
    requestedTimeZones.append(context.timeZone.identifier)
    requestedAgents.append(tool)
    if failingAgents.contains(tool) { throw StubError.importFailed }
    return totalsByAgent[tool] ?? []
  }
}
