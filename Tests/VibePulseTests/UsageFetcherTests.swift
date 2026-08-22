import XCTest

@testable import VibePulse

final class UsageFetcherTests: XCTestCase {
  func testServerURLConstrainsDiscoveryAndAgentRequestsToThirtyDays() throws {
    let now = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z"))
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

    let discoveryURL = try UsageFetcher.makeServerURL(
      configuredURL: "http://127.0.0.1:18080",
      agent: nil,
      now: now,
      timeZone: timeZone)
    let agentURL = try UsageFetcher.makeServerURL(
      configuredURL: "http://127.0.0.1:18080",
      agent: "claude",
      now: now,
      timeZone: timeZone)

    for url in [discoveryURL, agentURL] {
      let components = URLComponents(
        url: url, resolvingAgainstBaseURL: false)
      let queryItems = try XCTUnwrap(components?.queryItems)
      XCTAssertEqual(queryItems.first { $0.name == "from" }?.value, "2026-07-11")
      XCTAssertEqual(queryItems.first { $0.name == "no_default_range" }?.value, "true")
      XCTAssertEqual(queryItems.first { $0.name == "timezone" }?.value, "America/New_York")
    }
    XCTAssertNil(
      URLComponents(url: discoveryURL, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "agent" })
    XCTAssertEqual(
      URLComponents(url: agentURL, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "agent" }?.value,
      "claude")
  }

  func testFetchDailyTotalsRetriesWithoutBreakdownWhenFlagIsUnsupported() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-20",
            "totalCost": 4.5
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))
    var commands: [[String]] = []
    let fetcher = UsageFetcher(commandRunner: { arguments in
      commands.append(arguments)
      if arguments.contains("--breakdown") {
        throw UsageFetcher.FetchError.commandFailed(
          "Error: unknown flag: --breakdown\nUsage: agentsview usage daily [--timezone <zone>]")
      }
      return data
    })
    let context = UsageDateContext(
      now: Date(timeIntervalSince1970: 1_750_000_000),
      timeZone: TimeZone(identifier: "America/New_York")!)

    let totals = try fetcher.fetchDailyTotals(for: .claude, using: context)

    XCTAssertEqual(totals.map(\.cost), [4.5])
    XCTAssertEqual(commands.count, 2)
    XCTAssertTrue(commands[0].contains("--breakdown"))
    XCTAssertFalse(commands[1].contains("--breakdown"))
    XCTAssertEqual(
      commands[1],
      [
        "agentsview", "usage", "daily", "--format", "json", "--agent", "claude", "--since",
        "30d", "--timezone", "America/New_York", "--no-sync",
      ])
  }

  func testFetchDailyTotalsRejectsInvalidCalendarDate() throws {
    let json = #"{"daily":[{"date":"2026-02-30","totalCost":4.5}]}"#
    let data = try XCTUnwrap(json.data(using: .utf8))
    let fetcher = UsageFetcher(commandRunner: { _ in data })
    let context = UsageDateContext(
      now: Date(timeIntervalSince1970: 1_750_000_000),
      timeZone: TimeZone(identifier: "America/New_York")!)

    XCTAssertThrowsError(
      try fetcher.fetchDailyTotals(for: .claude, using: context)
    ) { error in
      guard case UsageFetcher.FetchError.invalidOutput = error else {
        return XCTFail("Expected invalid output, got \(error)")
      }
    }
  }

  func testUnsupportedTimezoneFlagFailsWithoutRetryingAnUnscopedCommand() {
    var commands: [[String]] = []
    let fetcher = UsageFetcher(commandRunner: { arguments in
      commands.append(arguments)
      throw UsageFetcher.FetchError.commandFailed(
        "Error: unknown flag: --timezone")
    })
    let context = UsageDateContext(
      now: Date(timeIntervalSince1970: 1_750_000_000),
      timeZone: TimeZone(identifier: "America/New_York")!)

    XCTAssertThrowsError(
      try fetcher.fetchDailyTotals(for: .claude, using: context)
    ) { error in
      guard case UsageFetcher.FetchError.unsupportedTimezone = error else {
        return XCTFail("Expected an unsupported timezone error, got \(error)")
      }
    }
    XCTAssertEqual(commands.count, 1)
    XCTAssertTrue(commands[0].contains("--timezone"))
  }

  func testParseDailyTotalsIncludesModelBreakdowns() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-02",
            "totalCost": 12.5,
            "modelBreakdowns": [
              { "modelName": "claude-fable-5", "cost": 10.25 },
              { "modelName": "claude-haiku-4-5-20251001", "cost": 2.25 }
            ]
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    XCTAssertEqual(totals.count, 1)
    XCTAssertEqual(totals[0].dateKey, "2026-07-02")
    XCTAssertEqual(totals[0].cost, 12.5, accuracy: 0.001)
    let modelBreakdowns = try XCTUnwrap(totals[0].modelBreakdowns)
    XCTAssertEqual(
      modelBreakdowns.map(\.modelName),
      [
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
      ])
    XCTAssertEqual(modelBreakdowns.map(\.cost), [10.25, 2.25])
  }

  func testParseDailyTotalsConvertsMicrodollarCostsToDollars() throws {
    let json = """
      {
        "schema_version": 4,
        "daily": [
          {
            "date": "2026-07-29",
            "totalCost": { "microdollars": 20061684 },
            "modelBreakdowns": [
              {
                "modelName": "claude-fable-5",
                "cost": { "microdollars": 18209461 }
              }
            ],
            "machineBreakdowns": [
              {
                "machineName": "host-a",
                "cost": { "microdollars": 20061684 }
              }
            ]
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    XCTAssertEqual(totals.count, 1)
    let total = try XCTUnwrap(totals.first)
    XCTAssertEqual(total.cost, 20.061684, accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(total.modelBreakdowns?.first).cost,
      18.209461,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(total.machineBreakdowns?.first).cost,
      20.061684,
      accuracy: 0.000_001)
  }

  func testParseDailyTotalsDistinguishesUnavailableModelBreakdownsFromExplicitEmpty() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-02",
            "totalCost": 12.5
          },
          {
            "date": "2026-07-03",
            "totalCost": 7.25,
            "modelBreakdowns": []
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    XCTAssertEqual(totals.count, 2)
    XCTAssertNil(totals[0].modelBreakdowns)
    XCTAssertNotNil(totals[1].modelBreakdowns)
    XCTAssertEqual(totals[1].modelBreakdowns?.count, 0)
  }

  func testParseDailyTotalsTreatsPartiallyMalformedModelBreakdownsAsUnavailable() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-02",
            "totalCost": 12.5,
            "modelBreakdowns": [
              { "modelName": "claude-fable-5", "cost": 10.25 },
              { "modelName": "claude-haiku-4-5-20251001" }
            ]
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    XCTAssertNil(totals[0].modelBreakdowns)
  }

  func testParseDailyTotalsIncludesValidMachineBreakdowns() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-16",
            "totalCost": 12.5,
            "machineBreakdowns": [
              { "machineName": "host-a", "cost": 8.25 },
              { "machineName": "host-b", "cost": "4.25" }
            ]
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    let machineBreakdowns = try XCTUnwrap(totals[0].machineBreakdowns)
    XCTAssertEqual(machineBreakdowns.map(\.machineName), ["host-a", "host-b"])
    XCTAssertEqual(machineBreakdowns.map(\.cost), [8.25, 4.25])
  }

  func testParseDailyTotalsRejectsPartiallyMalformedMachineBreakdowns() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-16",
            "totalCost": 12.5,
            "machineBreakdowns": [
              { "machineName": "host-a", "cost": 8.25 },
              { "machineName": "", "cost": 1 }
            ]
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    XCTAssertNil(totals[0].machineBreakdowns)
  }

  func testParseDailyTotalsDistinguishesUnavailableMachineBreakdownsFromExplicitEmpty() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-16",
            "totalCost": 12.5
          },
          {
            "date": "2026-07-17",
            "totalCost": 7.25,
            "machineBreakdowns": "malformed"
          },
          {
            "date": "2026-07-18",
            "totalCost": 4,
            "machineBreakdowns": []
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    let totals = try UsageFetcher.parseDailyTotals(data: data)

    XCTAssertNil(totals[0].machineBreakdowns)
    XCTAssertNil(totals[1].machineBreakdowns)
    XCTAssertNotNil(totals[2].machineBreakdowns)
    XCTAssertEqual(totals[2].machineBreakdowns?.count, 0)
  }

  func testParseDailyTotalsRejectsResponseWithMalformedRow() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-07-02",
            "totalCost": "NaN",
            "modelBreakdowns": [
              { "modelName": "claude-fable-5", "cost": 10.25 },
              { "modelName": "claude-haiku-4-5-20251001", "cost": "Infinity" }
            ]
          },
          {
            "date": "2026-07-03",
            "totalCost": { "microdollars": "Infinity" }
          },
          {
            "date": "2026-07-04",
            "totalCost": 4.5
          }
        ]
      }
      """
    let data = try XCTUnwrap(json.data(using: .utf8))

    XCTAssertThrowsError(
      try UsageFetcher.parseDailyTotals(data: data)
    ) { error in
      guard case UsageFetcher.FetchError.invalidOutput = error else {
        return XCTFail("Expected invalid output, got \(error)")
      }
    }
  }

  func testParseDailyTotalsRejectsMissingDailyArray() throws {
    let data = try XCTUnwrap(#"{"schema_version":4}"#.data(using: .utf8))

    XCTAssertThrowsError(
      try UsageFetcher.parseDailyTotals(data: data)
    ) { error in
      guard case UsageFetcher.FetchError.invalidOutput = error else {
        return XCTFail("Expected invalid output, got \(error)")
      }
    }
  }

  func testParseDailyTotalsAcceptsEmptyDailyArray() throws {
    let data = try XCTUnwrap(#"{"daily":[]}"#.data(using: .utf8))

    XCTAssertTrue(try UsageFetcher.parseDailyTotals(data: data).isEmpty)
  }

  func testParseDiscoveredAgentsSumsThirtyDayBreakdownsAndDropsZeroCostAgents() throws {
    let json = """
      {
        "schema_version": 4,
        "daily": [
          {
            "date": "2026-07-01",
            "agentBreakdowns": [
              { "agent": "claude", "cost": { "microdollars": 2500000 } },
              { "agent": "zero-agent", "cost": { "microdollars": 0 } }
            ]
          },
          {
            "date": "2026-07-02",
            "agentBreakdowns": [
              { "agent": "claude", "cost": { "microdollars": 1500000 } },
              { "agent": "future-agent", "cost": { "microdollars": 3000000 } }
            ]
          }
        ]
      }
      """

    let agents = try UsageFetcher.parseDiscoveredAgents(
      data: try XCTUnwrap(json.data(using: .utf8)))

    XCTAssertEqual(agents.map(\.rawValue), ["claude", "future-agent"])
  }

  func testParseDiscoveredAgentsReturnsEmptyForValidEmptyReport() throws {
    let data = try XCTUnwrap(#"{"daily":[]}"#.data(using: .utf8))

    XCTAssertEqual(try UsageFetcher.parseDiscoveredAgents(data: data), [])
  }

  func testParseDiscoveredAgentsSkipsNonObjectBreakdownEntriesAndReturnsValidAgents() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-08-07",
            "agentBreakdowns": [
              { "agent": "claude", "cost": 5.0 },
              null
            ]
          }
        ]
      }
      """

    let agents = try UsageFetcher.parseDiscoveredAgents(
      data: try XCTUnwrap(json.data(using: .utf8)))

    XCTAssertEqual(agents.map(\.rawValue), ["claude"])
  }

  func testParseDiscoveredAgentsSkipsMalformedBreakdownEntriesAndReturnsValidAgents() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-08-07",
            "agentBreakdowns": [
              { "agent": "claude", "cost": 5.0 },
              { "agent": "codex" }
            ]
          }
        ]
      }
      """

    let agents = try UsageFetcher.parseDiscoveredAgents(
      data: try XCTUnwrap(json.data(using: .utf8)))

    XCTAssertEqual(agents.map(\.rawValue), ["claude"])
  }

  func testParseDiscoveredAgentsSkipsDaysMissingAgentBreakdowns() throws {
    let json = """
      {
        "daily": [
          {
            "date": "2026-08-06",
            "agentBreakdowns": [
              { "agent": "claude", "cost": 5.0 }
            ]
          },
          {
            "date": "2026-08-07"
          }
        ]
      }
      """

    let agents = try UsageFetcher.parseDiscoveredAgents(
      data: try XCTUnwrap(json.data(using: .utf8)))

    XCTAssertEqual(agents.map(\.rawValue), ["claude"])
  }

  func testParseDiscoveredAgentsSkipsAllMalformedBreakdownEntriesAndReturnsEmpty() throws {
    let data = try XCTUnwrap(
      #"{"daily":[{"date":"2026-07-02","agentBreakdowns":[{"agent":"future-agent"}]}]}"#
        .data(using: .utf8))

    XCTAssertEqual(try UsageFetcher.parseDiscoveredAgents(data: data), [])
  }
}
