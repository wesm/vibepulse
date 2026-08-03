import XCTest

@testable import VibePulse

final class UsageFetcherTests: XCTestCase {
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
        throw UsageFetcher.FetchError.commandFailed("Error: unknown flag: --breakdown")
      }
      return data
    })

    let totals = try fetcher.fetchDailyTotals(for: .claude)

    XCTAssertEqual(totals.map(\.cost), [4.5])
    XCTAssertEqual(commands.count, 2)
    XCTAssertTrue(commands[0].contains("--breakdown"))
    XCTAssertFalse(commands[1].contains("--breakdown"))
    XCTAssertEqual(
      commands[1],
      [
        "agentsview", "usage", "daily", "--format", "json", "--agent", "claude", "--since",
        "30d", "--no-sync",
      ])
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

  func testParseDiscoveredAgentsRejectsMalformedRequiredBreakdownRows() throws {
    let data = try XCTUnwrap(
      #"{"daily":[{"date":"2026-07-02","agentBreakdowns":[{"agent":"future-agent"}]}]}"#
        .data(using: .utf8))

    XCTAssertThrowsError(try UsageFetcher.parseDiscoveredAgents(data: data))
  }
}
