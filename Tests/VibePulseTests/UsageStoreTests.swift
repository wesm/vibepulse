import SQLite3
import XCTest

@testable import VibePulse

final class UsageStoreTests: XCTestCase {
  func testCurrentDayInvalidationUsesRecordedAtInsteadOfDateKey() throws {
    let store = try UsageStore(path: ":memory:")
    let recordedAt = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z"))
    let oldTimeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let newTimeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let oldContext = UsageDateContext(now: recordedAt, timeZone: oldTimeZone)
    let newContext = UsageDateContext(now: recordedAt, timeZone: newTimeZone)
    let priorRecordedAt = newContext.startOfToday.addingTimeInterval(-1)
    let priorContext = UsageDateContext(now: priorRecordedAt, timeZone: newTimeZone)

    try store.insertSample(
      tool: .claude,
      totalCost: 100,
      recordedAt: recordedAt,
      dateContext: oldContext)
    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [DailyModelBreakdown(modelName: "model", cost: 100)],
      recordedAt: recordedAt,
      dateContext: oldContext)
    try store.insertMachineSamplesForRefresh(
      tool: .claude,
      machineBreakdowns: [DailyMachineBreakdown(machineName: "machine", cost: 100)],
      recordedAt: recordedAt,
      dateContext: oldContext)

    try store.insertSample(
      tool: .claude,
      totalCost: 5,
      recordedAt: priorRecordedAt,
      dateContext: priorContext)
    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [DailyModelBreakdown(modelName: "model", cost: 5)],
      recordedAt: priorRecordedAt,
      dateContext: priorContext)
    try store.insertMachineSamplesForRefresh(
      tool: .claude,
      machineBreakdowns: [DailyMachineBreakdown(machineName: "machine", cost: 5)],
      recordedAt: priorRecordedAt,
      dateContext: priorContext)

    try store.deleteCurrentDaySamples(using: newContext)

    XCTAssertEqual(
      store.fetchSamples(tool: .claude, from: Date.distantPast, to: Date.distantFuture)
        .map(\.recordedAt),
      [priorRecordedAt])
    XCTAssertEqual(
      store.fetchModelSamples(
        tools: [.claude], from: Date.distantPast, to: Date.distantFuture
      )
      .map(\.recordedAt),
      [priorRecordedAt])
    XCTAssertEqual(
      store.fetchMachineSamples(
        tools: [.claude], from: Date.distantPast, to: Date.distantFuture
      )
      .map(\.recordedAt),
      [priorRecordedAt])
  }

  func testCurrentDayInvalidationRemovesOldTimezoneDateKeyCollisions() throws {
    let store = try UsageStore(path: ":memory:")
    let newNow = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z"))
    let oldSampleRecordedAt =
      newNow
      .addingTimeInterval(-19 * 60 * 60)
    let oldTimeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let newTimeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let oldContext = UsageDateContext(now: oldSampleRecordedAt, timeZone: oldTimeZone)
    let newContext = UsageDateContext(now: newNow, timeZone: newTimeZone)

    XCTAssertEqual(oldContext.todayKey, newContext.todayKey)
    XCTAssertLessThan(oldSampleRecordedAt, newContext.startOfToday)

    try store.insertSample(
      tool: .claude,
      totalCost: 100,
      recordedAt: oldSampleRecordedAt,
      dateContext: oldContext)
    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [DailyModelBreakdown(modelName: "model", cost: 100)],
      recordedAt: oldSampleRecordedAt,
      dateContext: oldContext)
    try store.insertMachineSamplesForRefresh(
      tool: .claude,
      machineBreakdowns: [DailyMachineBreakdown(machineName: "machine", cost: 100)],
      recordedAt: oldSampleRecordedAt,
      dateContext: oldContext)

    try store.deleteCurrentDaySamples(using: newContext)
    XCTAssertEqual(try store.backfillSampleDeltas(), 0)
    XCTAssertEqual(try store.backfillModelSampleDeltas(), 0)
    XCTAssertEqual(try store.backfillMachineSampleDeltas(), 0)

    XCTAssertTrue(
      store.fetchSamples(tool: .claude, from: Date.distantPast, to: Date.distantFuture).isEmpty)
    XCTAssertTrue(
      store.fetchModelSamples(
        tools: [.claude], from: Date.distantPast, to: Date.distantFuture
      ).isEmpty)
    XCTAssertTrue(
      store.fetchMachineSamples(
        tools: [.claude], from: Date.distantPast, to: Date.distantFuture
      ).isEmpty)
  }

  func testSampleBreakdownDeltasUseRecordedAtIntervalAcrossTimezoneDateKeys() throws {
    let store = try UsageStore(path: ":memory:")
    let first = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z"))
    let second = first.addingTimeInterval(60 * 10)
    let oldContext = UsageDateContext(
      now: first,
      timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
    let newContext = UsageDateContext(
      now: second,
      timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))

    try store.insertSample(
      tool: .claude, totalCost: 100, recordedAt: first, dateContext: oldContext)
    try store.insertSample(
      tool: .claude, totalCost: 110, recordedAt: second, dateContext: newContext)
    try store.insertModelSample(
      tool: .claude,
      modelName: "model",
      totalCost: 100,
      recordedAt: first,
      dateContext: oldContext)
    try store.insertModelSample(
      tool: .claude,
      modelName: "model",
      totalCost: 110,
      recordedAt: second,
      dateContext: newContext)
    try store.insertMachineSample(
      tool: .claude,
      machineName: "machine",
      totalCost: 100,
      recordedAt: first,
      dateContext: oldContext)
    try store.insertMachineSample(
      tool: .claude,
      machineName: "machine",
      totalCost: 110,
      recordedAt: second,
      dateContext: newContext)

    XCTAssertEqual(
      store.fetchSamples(tool: .claude, from: first, to: second).map(\.deltaCost),
      [100, 10])
    XCTAssertEqual(
      store.fetchModelSamples(tools: [.claude], from: first, to: second).map(\.deltaCost),
      [100, 10])
    XCTAssertEqual(
      store.fetchMachineSamples(tools: [.claude], from: first, to: second).map(\.deltaCost),
      [100, 10])
  }

  func testDailyRollupReadsRespectInclusiveDateBounds() throws {
    let store = try UsageStore(path: ":memory:")
    let context = UsageDateContext(
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")),
      timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
    let totals = [
      DailyTotal(
        dateKey: "2026-07-01",
        cost: 1,
        modelBreakdowns: [DailyModelBreakdown(modelName: "model", cost: 1)],
        machineBreakdowns: [DailyMachineBreakdown(machineName: "machine", cost: 1)]),
      DailyTotal(
        dateKey: "2026-07-02",
        cost: 2,
        modelBreakdowns: [DailyModelBreakdown(modelName: "model", cost: 2)],
        machineBreakdowns: [DailyMachineBreakdown(machineName: "machine", cost: 2)]),
      DailyTotal(
        dateKey: "2026-07-03",
        cost: 3,
        modelBreakdowns: [DailyModelBreakdown(modelName: "model", cost: 3)],
        machineBreakdowns: [DailyMachineBreakdown(machineName: "machine", cost: 3)]),
    ]
    try store.upsertDailyTotals(tool: .claude, totals: totals, dateContext: context)

    XCTAssertEqual(
      store.fetchDailyRollups(
        since: "2026-07-02", through: "2026-07-02", timeZone: context.timeZone
      )
      .map(\.dateKey),
      ["2026-07-02"])
    XCTAssertEqual(
      store.fetchModelDailyRollups(
        since: "2026-07-02", through: "2026-07-02", tools: [.claude], timeZone: context.timeZone
      )
      .map(\.dateKey),
      ["2026-07-02"])
    XCTAssertEqual(
      store.fetchMachineDailyRollups(
        since: "2026-07-02", through: "2026-07-02", tools: [.claude], timeZone: context.timeZone
      )
      .map(\.dateKey),
      ["2026-07-02"])
  }

  func testReplaceDailyTotalsRemovesMissingRollupsWithinRefreshWindow() throws {
    let store = try UsageStore(path: ":memory:")
    let context = UsageDateContext(
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")),
      timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
    let staleDate = context.calendar.date(byAdding: .day, value: -1, to: context.startOfToday)!
    let outsideDate = context.calendar.date(byAdding: .day, value: -30, to: context.startOfToday)!
    let futureDate = context.calendar.date(byAdding: .day, value: 1, to: context.startOfToday)!
    let staleDateKey = DateHelper.dateKey(for: staleDate, in: context.timeZone)
    let outsideDateKey = DateHelper.dateKey(for: outsideDate, in: context.timeZone)
    let futureDateKey = DateHelper.dateKey(for: futureDate, in: context.timeZone)

    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: staleDateKey,
          cost: 2,
          modelBreakdowns: [DailyModelBreakdown(modelName: "old-model", cost: 2)],
          machineBreakdowns: [DailyMachineBreakdown(machineName: "old-machine", cost: 2)]),
        DailyTotal(
          dateKey: context.todayKey,
          cost: 3,
          modelBreakdowns: [DailyModelBreakdown(modelName: "old-model", cost: 3)],
          machineBreakdowns: [DailyMachineBreakdown(machineName: "old-machine", cost: 3)]),
        DailyTotal(
          dateKey: outsideDateKey,
          cost: 4,
          modelBreakdowns: [DailyModelBreakdown(modelName: "old-model", cost: 4)],
          machineBreakdowns: [DailyMachineBreakdown(machineName: "old-machine", cost: 4)]),
        DailyTotal(
          dateKey: futureDateKey,
          cost: 5,
          modelBreakdowns: [DailyModelBreakdown(modelName: "old-model", cost: 5)],
          machineBreakdowns: [DailyMachineBreakdown(machineName: "old-machine", cost: 5)]),
      ],
      dateContext: context)

    try store.replaceDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: context.todayKey,
          cost: 7,
          modelBreakdowns: [DailyModelBreakdown(modelName: "new-model", cost: 7)],
          machineBreakdowns: [DailyMachineBreakdown(machineName: "new-machine", cost: 7)])
      ],
      dateContext: context)

    XCTAssertEqual(
      store.fetchDailyRollups(
        since: context.usageWindowStartKey,
        through: futureDateKey,
        timeZone: context.timeZone
      )
      .map(\.dateKey),
      [context.todayKey])
    XCTAssertEqual(
      store.fetchModelDailyRollups(
        since: context.usageWindowStartKey,
        through: futureDateKey,
        tools: [.claude],
        timeZone: context.timeZone
      )
      .map(\.modelName),
      ["new-model"])
    XCTAssertEqual(
      store.fetchMachineDailyRollups(
        since: context.usageWindowStartKey,
        through: futureDateKey,
        tools: [.claude],
        timeZone: context.timeZone
      )
      .map(\.machineName),
      ["new-machine"])
    XCTAssertEqual(store.dailyTotal(for: outsideDateKey, tool: .claude), 4)
  }

  func testRefreshWindowRollupDeletionNormalizesStoredDateKeys() throws {
    let path = temporaryStorePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try UsageStore(path: path)
    let context = UsageDateContext(
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")),
      timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
    let historicalDateKey = "2026-07-02"
    let staleDateKey = "17 Aug 2026"

    try insertRawDailyRollup(
      path: path, dateKey: "July 2, 2026", tool: .claude, totalCost: 1)
    try insertRawDailyRollup(
      path: path, dateKey: staleDateKey, tool: .claude, totalCost: 2)
    try insertRawModelDailyRollup(
      path: path, dateKey: "July 2, 2026", tool: .claude,
      modelName: "historical-model", totalCost: 1)
    try insertRawModelDailyRollup(
      path: path, dateKey: staleDateKey, tool: .claude,
      modelName: "stale-model", totalCost: 2)
    try insertRawMachineDailyRollup(
      path: path, dateKey: "July 2, 2026", tool: .claude,
      machineName: "historical-machine", totalCost: 1)
    try insertRawMachineDailyRollup(
      path: path, dateKey: staleDateKey, tool: .claude,
      machineName: "stale-machine", totalCost: 2)

    try store.deleteRefreshWindowRollups(using: context)

    XCTAssertEqual(
      store.fetchDailyRollups(
        since: historicalDateKey, through: historicalDateKey, timeZone: context.timeZone
      )
      .map(\.totalCost),
      [1])
    XCTAssertTrue(
      store.fetchDailyRollups(
        since: context.usageWindowStartKey,
        through: context.todayKey,
        timeZone: context.timeZone
      ).isEmpty)
    XCTAssertEqual(
      store.fetchModelDailyRollups(
        since: historicalDateKey,
        through: historicalDateKey,
        tools: [.claude],
        timeZone: context.timeZone
      )
      .map(\.totalCost),
      [1])
    XCTAssertTrue(
      store.fetchModelDailyRollups(
        since: context.usageWindowStartKey,
        through: context.todayKey,
        tools: [.claude],
        timeZone: context.timeZone
      ).isEmpty)
    XCTAssertEqual(
      store.fetchMachineDailyRollups(
        since: historicalDateKey,
        through: historicalDateKey,
        tools: [.claude],
        timeZone: context.timeZone
      )
      .map(\.totalCost),
      [1])
    XCTAssertTrue(
      store.fetchMachineDailyRollups(
        since: context.usageWindowStartKey,
        through: context.todayKey,
        tools: [.claude],
        timeZone: context.timeZone
      ).isEmpty)
  }

  func testStoreRoundTripsArbitraryAgentIdentifiers() throws {
    let store = try UsageStore(path: ":memory:")
    let agent = UsageAgent("future-agent")
    let date = Date()
    let dateKey = DateHelper.dateKey(for: date)

    try store.upsertDailyTotals(
      tool: agent,
      totals: [DailyTotal(dateKey: dateKey, cost: 4.25)])
    try store.insertSample(tool: agent, totalCost: 4.25, recordedAt: date)

    XCTAssertEqual(store.dailyTotal(for: dateKey, tool: agent), 4.25)
    XCTAssertEqual(
      store.fetchSamples(tool: agent, from: Date.distantPast, to: Date.distantFuture).map(\.tool),
      [agent])
    XCTAssertEqual(store.fetchDailyRollups(since: dateKey).map(\.tool), [agent])
  }

  func testStoredAgentsIncludesUnknownAgentsFromPersistedUsage() throws {
    let store = try UsageStore(path: ":memory:")
    let agent = UsageAgent("future-agent")

    try store.upsertDailyTotals(
      tool: agent,
      totals: [DailyTotal(dateKey: "2026-07-02", cost: 1)])

    XCTAssertEqual(store.storedAgents(), [agent])
  }

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

  func testUpsertDailyTotalsPersistsModelRollupsPerAgent() throws {
    let store = try UsageStore(path: ":memory:")
    let totals = [
      DailyTotal(
        dateKey: "2026-07-02",
        cost: 12.5,
        modelBreakdowns: [
          DailyModelBreakdown(modelName: "claude-fable-5", cost: 10.25),
          DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 2.25),
        ])
    ]

    try store.upsertDailyTotals(tool: .claude, totals: totals)

    let rollups = store.fetchModelDailyRollups(since: "2026-07-01", tools: [.claude])
    XCTAssertEqual(rollups.map(\.dateKey), ["2026-07-02", "2026-07-02"])
    XCTAssertEqual(rollups.map(\.tool), [.claude, .claude])
    XCTAssertEqual(
      rollups.map(\.modelName),
      [
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
      ])
    XCTAssertEqual(rollups.map(\.totalCost), [10.25, 2.25])
  }

  func testUpsertDailyTotalsRemovesStaleModelRollups() throws {
    let store = try UsageStore(path: ":memory:")

    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: "2026-07-02",
          cost: 12.5,
          modelBreakdowns: [
            DailyModelBreakdown(modelName: "claude-fable-5", cost: 10.25),
            DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 2.25),
          ])
      ])

    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: "2026-07-02",
          cost: 10.75,
          modelBreakdowns: [
            DailyModelBreakdown(modelName: "claude-fable-5", cost: 10.75)
          ])
      ])

    let rollups = store.fetchModelDailyRollups(since: "2026-07-01", tools: [.claude])
    XCTAssertEqual(rollups.map(\.modelName), ["claude-fable-5"])
    XCTAssertEqual(rollups.map(\.totalCost), [10.75])
  }

  func testUpsertDailyTotalsPreservesModelRollupsWhenBreakdownUnavailable() throws {
    let store = try UsageStore(path: ":memory:")

    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: "2026-07-02",
          cost: 12.5,
          modelBreakdowns: [
            DailyModelBreakdown(modelName: "claude-fable-5", cost: 10.25),
            DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 2.25),
          ])
      ])

    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(dateKey: "2026-07-02", cost: 14)
      ])

    let rollups = store.fetchModelDailyRollups(since: "2026-07-01", tools: [.claude])
    XCTAssertEqual(
      rollups.map(\.modelName),
      [
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
      ])
    XCTAssertEqual(rollups.map(\.totalCost), [10.25, 2.25])
  }

  func testUpsertDailyTotalsNormalizesModelRollupDateKeysBeforeReplacing() throws {
    let store = try UsageStore(path: ":memory:")

    try store.upsertDailyTotals(
      tool: .codex,
      totals: [
        DailyTotal(
          dateKey: "July 2, 2026",
          cost: 4,
          modelBreakdowns: [
            DailyModelBreakdown(modelName: "gpt-5", cost: 4)
          ])
      ])

    try store.upsertDailyTotals(
      tool: .codex,
      totals: [
        DailyTotal(
          dateKey: "2026-07-02",
          cost: 7,
          modelBreakdowns: [
            DailyModelBreakdown(modelName: "gpt-5", cost: 7)
          ])
      ])

    let rollups = store.fetchModelDailyRollups(since: "2026-07-01", tools: [.codex])
    XCTAssertEqual(rollups.map(\.dateKey), ["2026-07-02"])
    XCTAssertEqual(rollups.map(\.modelName), ["gpt-5"])
    XCTAssertEqual(rollups.map(\.totalCost), [7])
  }

  func testNormalizeModelDailyRollupDatesMergesExistingDuplicateLogicalDates() throws {
    let dbURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let store = try UsageStore(path: dbURL.path)
    try insertRawModelDailyRollup(
      path: dbURL.path,
      dateKey: "July 2, 2026",
      tool: .codex,
      modelName: "gpt-5",
      totalCost: 4)
    try insertRawModelDailyRollup(
      path: dbURL.path,
      dateKey: "2026-07-02",
      tool: .codex,
      modelName: "gpt-5",
      totalCost: 7)

    let normalizedCount = try store.normalizeModelDailyRollupDates(for: .codex)

    let rollups = store.fetchModelDailyRollups(since: "2026-07-01", tools: [.codex])
    XCTAssertEqual(normalizedCount, 1)
    XCTAssertEqual(rollups.map(\.dateKey), ["2026-07-02"])
    XCTAssertEqual(rollups.map(\.modelName), ["gpt-5"])
    XCTAssertEqual(rollups.map(\.totalCost), [7])
  }

  func testInsertModelSamplesForRefreshResetsModelsMissingFromCurrentBreakdown() throws {
    let store = try UsageStore(path: ":memory:")
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let second = calendar.date(byAdding: .minute, value: 30, to: start)!

    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [
        DailyModelBreakdown(modelName: "claude-fable-5", cost: 10),
        DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 2),
      ],
      recordedAt: first)

    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [
        DailyModelBreakdown(modelName: "claude-fable-5", cost: 12)
      ],
      recordedAt: second)

    let samples = store.fetchModelSamples(tools: [.claude], from: start, to: second)
    XCTAssertEqual(samples.count, 4)
    XCTAssertEqual(
      samples.map(\.modelName),
      [
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
      ])
    XCTAssertEqual(samples.map(\.totalCost), [10, 2, 12, 0])
    XCTAssertEqual(samples.map(\.deltaCost), [10, 2, 2, 0])
  }

  func testModelSampleDeltaIgnoresResetThenReappearBelowPreviousHighWaterMark() throws {
    let store = try UsageStore(path: ":memory:")
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let reset = calendar.date(byAdding: .minute, value: 30, to: start)!
    let reappearSameTotal = calendar.date(byAdding: .minute, value: 45, to: start)!
    let reappearHigherTotal = calendar.date(byAdding: .minute, value: 60, to: start)!

    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [
        DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 2)
      ],
      recordedAt: first)

    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [],
      recordedAt: reset)

    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [
        DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 2)
      ],
      recordedAt: reappearSameTotal)

    try store.insertModelSamplesForRefresh(
      tool: .claude,
      modelBreakdowns: [
        DailyModelBreakdown(modelName: "claude-haiku-4-5-20251001", cost: 5)
      ],
      recordedAt: reappearHigherTotal)

    let samples = store.fetchModelSamples(tools: [.claude], from: start, to: reappearHigherTotal)

    XCTAssertEqual(samples.map(\.totalCost), [2, 0, 2, 5])
    XCTAssertEqual(samples.map(\.deltaCost), [2, 0, 0, 3])
  }

  func testModelSampleDeltaCalculationIsScopedByAgentAndModel() throws {
    let store = try UsageStore(path: ":memory:")
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let second = calendar.date(byAdding: .minute, value: 30, to: start)!

    try store.insertModelSample(
      tool: .claude, modelName: "shared-model", totalCost: 10, recordedAt: first)
    try store.insertModelSample(
      tool: .codex, modelName: "shared-model", totalCost: 4, recordedAt: first)
    try store.insertModelSample(
      tool: .claude, modelName: "shared-model", totalCost: 15, recordedAt: second)

    let samples = store.fetchModelSamples(tools: [.claude, .codex], from: start, to: second)

    XCTAssertEqual(samples.count, 3)
    XCTAssertEqual(samples[0].deltaCost, 10, accuracy: 0.001)
    XCTAssertEqual(samples[1].deltaCost, 4, accuracy: 0.001)
    XCTAssertEqual(samples[2].deltaCost, 5, accuracy: 0.001)
  }

  func testBackfillModelSampleDeltasIsScopedByAgentModelAndDate() throws {
    let path = temporaryStorePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let second = calendar.date(byAdding: .minute, value: 30, to: start)!

    do {
      let store = try UsageStore(path: path)
      try store.insertModelSample(
        tool: .claude, modelName: "shared-model", totalCost: 10, recordedAt: first)
      try store.insertModelSample(
        tool: .codex, modelName: "shared-model", totalCost: 4, recordedAt: first)
      try store.insertModelSample(
        tool: .claude, modelName: "shared-model", totalCost: 15, recordedAt: second)
    }

    try updateRawModelSampleDeltas(path: path, deltaCost: 0)

    let store = try UsageStore(path: path)
    let updatedCount = try store.backfillModelSampleDeltas()
    let samples = store.fetchModelSamples(tools: [.claude, .codex], from: start, to: second)

    XCTAssertEqual(updatedCount, 3)
    XCTAssertEqual(samples.map(\.deltaCost), [10, 4, 5])
  }

  func testBackfillModelSampleDeltasIgnoresResetThenReappearBelowPreviousHighWaterMark() throws {
    let path = temporaryStorePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let reset = calendar.date(byAdding: .minute, value: 30, to: start)!
    let reappearSameTotal = calendar.date(byAdding: .minute, value: 45, to: start)!
    let reappearHigherTotal = calendar.date(byAdding: .minute, value: 60, to: start)!

    do {
      let store = try UsageStore(path: path)
      try store.insertModelSample(
        tool: .claude,
        modelName: "claude-haiku-4-5-20251001",
        totalCost: 2,
        recordedAt: first)
      try store.insertModelSample(
        tool: .claude,
        modelName: "claude-haiku-4-5-20251001",
        totalCost: 0,
        recordedAt: reset)
      try store.insertModelSample(
        tool: .claude,
        modelName: "claude-haiku-4-5-20251001",
        totalCost: 2,
        recordedAt: reappearSameTotal)
      try store.insertModelSample(
        tool: .claude,
        modelName: "claude-haiku-4-5-20251001",
        totalCost: 5,
        recordedAt: reappearHigherTotal)
    }

    try updateRawModelSampleDeltas(path: path, deltaCosts: [2, 0, 2, 3])

    let store = try UsageStore(path: path)
    let updatedCount = try store.backfillModelSampleDeltas()
    let samples = store.fetchModelSamples(tools: [.claude], from: start, to: reappearHigherTotal)

    XCTAssertEqual(updatedCount, 1)
    XCTAssertEqual(samples.map(\.totalCost), [2, 0, 2, 5])
    XCTAssertEqual(samples.map(\.deltaCost), [2, 0, 0, 3])
  }

  func testMigrationBackfillsLegacyModelSampleDeltas() throws {
    let path = temporaryStorePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let second = calendar.date(byAdding: .minute, value: 30, to: start)!

    try createLegacyModelSamples(
      path: path,
      samples: [
        (.claude, "shared-model", first, 10),
        (.codex, "shared-model", first, 4),
        (.claude, "shared-model", second, 15),
      ])

    let store = try UsageStore(path: path)
    let samples = store.fetchModelSamples(tools: [.claude, .codex], from: start, to: second)

    XCTAssertEqual(samples.map(\.deltaCost), [10, 4, 5])
  }

  func testUpsertDailyTotalsPersistsAndReplacesMachineRollupsPerTool() throws {
    let store = try UsageStore(path: ":memory:")

    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: "2026-07-16",
          cost: 12.5,
          machineBreakdowns: [
            DailyMachineBreakdown(machineName: "host-a", cost: 8.25),
            DailyMachineBreakdown(machineName: "host-b", cost: 4.25),
          ])
      ])
    try store.upsertDailyTotals(
      tool: .claude,
      totals: [
        DailyTotal(
          dateKey: "2026-07-16",
          cost: 9,
          machineBreakdowns: [
            DailyMachineBreakdown(machineName: "host-a", cost: 9)
          ])
      ])

    let rollups = store.fetchMachineDailyRollups(since: "2026-07-01", tools: [.claude])
    XCTAssertEqual(rollups.map(\.dateKey), ["2026-07-16"])
    XCTAssertEqual(rollups.map(\.tool), [.claude])
    XCTAssertEqual(rollups.map(\.machineName), ["host-a"])
    XCTAssertEqual(rollups.map(\.totalCost), [9])
  }

  func testUpsertDailyTotalsPreservesMachineRollupsWhenBreakdownUnavailable() throws {
    let store = try UsageStore(path: ":memory:")

    try store.upsertDailyTotals(
      tool: .codex,
      totals: [
        DailyTotal(
          dateKey: "2026-07-16",
          cost: 7,
          machineBreakdowns: [
            DailyMachineBreakdown(machineName: "host-a", cost: 7)
          ])
      ])
    try store.upsertDailyTotals(
      tool: .codex,
      totals: [DailyTotal(dateKey: "2026-07-16", cost: 8)])

    let rollups = store.fetchMachineDailyRollups(since: "2026-07-01", tools: [.codex])
    XCTAssertEqual(rollups.map(\.machineName), ["host-a"])
    XCTAssertEqual(rollups.map(\.totalCost), [7])
  }

  func testInsertMachineSamplesForRefreshResetsAndUsesHighWaterMark() throws {
    let store = try UsageStore(path: ":memory:")
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let reset = calendar.date(byAdding: .minute, value: 30, to: start)!
    let reappearSame = calendar.date(byAdding: .minute, value: 45, to: start)!
    let reappearHigher = calendar.date(byAdding: .hour, value: 1, to: start)!

    try store.insertMachineSamplesForRefresh(
      tool: .claude,
      machineBreakdowns: [DailyMachineBreakdown(machineName: "host-a", cost: 2)],
      recordedAt: first)
    try store.insertMachineSamplesForRefresh(
      tool: .claude, machineBreakdowns: [], recordedAt: reset)
    try store.insertMachineSamplesForRefresh(
      tool: .claude,
      machineBreakdowns: [DailyMachineBreakdown(machineName: "host-a", cost: 2)],
      recordedAt: reappearSame)
    try store.insertMachineSamplesForRefresh(
      tool: .claude,
      machineBreakdowns: [DailyMachineBreakdown(machineName: "host-a", cost: 5)],
      recordedAt: reappearHigher)

    let samples = store.fetchMachineSamples(
      tools: [.claude], from: start, to: reappearHigher)
    XCTAssertEqual(samples.map(\.totalCost), [2, 0, 2, 5])
    XCTAssertEqual(samples.map(\.deltaCost), [2, 0, 0, 3])
  }

  func testMachineSampleDeltaCalculationIsScopedByAgentAndMachine() throws {
    let store = try UsageStore(path: ":memory:")
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let second = calendar.date(byAdding: .minute, value: 30, to: start)!

    try store.insertMachineSample(
      tool: .claude, machineName: "shared-host", totalCost: 10, recordedAt: first)
    try store.insertMachineSample(
      tool: .codex, machineName: "shared-host", totalCost: 4, recordedAt: first)
    try store.insertMachineSample(
      tool: .claude, machineName: "shared-host", totalCost: 15, recordedAt: second)

    let samples = store.fetchMachineSamples(
      tools: [.claude, .codex], from: start, to: second)
    XCTAssertEqual(samples.map(\.deltaCost), [10, 4, 5])
  }

  func testNormalizeMachineDailyRollupDatesMergesExistingDuplicateLogicalDates() throws {
    let path = temporaryStorePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try UsageStore(path: path)
    try insertRawMachineDailyRollup(
      path: path, dateKey: "July 16, 2026", tool: .codex,
      machineName: "host-a", totalCost: 4)
    try insertRawMachineDailyRollup(
      path: path, dateKey: "2026-07-16", tool: .codex,
      machineName: "host-a", totalCost: 7)

    let normalizedCount = try store.normalizeMachineDailyRollupDates(for: .codex)

    let rollups = store.fetchMachineDailyRollups(since: "2026-07-01", tools: [.codex])
    XCTAssertEqual(normalizedCount, 1)
    XCTAssertEqual(rollups.map(\.dateKey), ["2026-07-16"])
    XCTAssertEqual(rollups.map(\.machineName), ["host-a"])
    XCTAssertEqual(rollups.map(\.totalCost), [7])
  }

  func testMigrationBackfillsLegacyMachineSampleDeltas() throws {
    let path = temporaryStorePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let calendar = Calendar.current
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16))!
    let first = calendar.date(byAdding: .minute, value: 5, to: start)!
    let second = calendar.date(byAdding: .minute, value: 30, to: start)!

    try createLegacyMachineSamples(
      path: path,
      samples: [
        (.claude, "shared-host", first, 10),
        (.codex, "shared-host", first, 4),
        (.claude, "shared-host", second, 15),
      ])

    let store = try UsageStore(path: path)
    let samples = store.fetchMachineSamples(
      tools: [.claude, .codex], from: start, to: second)
    XCTAssertEqual(samples.map(\.deltaCost), [10, 4, 5])
  }

  private func insertRawModelDailyRollup(
    path: String,
    dateKey: String,
    tool: UsageAgent,
    modelName: String,
    totalCost: Double
  ) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 1)
    }
    defer { sqlite3_close(db) }

    let sql = """
      INSERT INTO model_daily_rollups (date_key, tool, model_name, total_cost, updated_at)
      VALUES (?, ?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 2)
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (dateKey as NSString).utf8String, -1, nil)
    sqlite3_bind_text(statement, 2, (tool.rawValue as NSString).utf8String, -1, nil)
    sqlite3_bind_text(statement, 3, (modelName as NSString).utf8String, -1, nil)
    sqlite3_bind_double(statement, 4, totalCost)
    sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "UsageStoreTests", code: 3)
    }
  }

  private func insertRawDailyRollup(
    path: String,
    dateKey: String,
    tool: UsageAgent,
    totalCost: Double
  ) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 28)
    }
    defer { sqlite3_close(db) }

    let sql = """
      INSERT INTO daily_rollups (date_key, tool, total_cost, updated_at)
      VALUES (?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 29)
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (dateKey as NSString).utf8String, -1, nil)
    sqlite3_bind_text(statement, 2, (tool.rawValue as NSString).utf8String, -1, nil)
    sqlite3_bind_double(statement, 3, totalCost)
    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "UsageStoreTests", code: 30)
    }
  }

  private func insertRawMachineDailyRollup(
    path: String,
    dateKey: String,
    tool: UsageAgent,
    machineName: String,
    totalCost: Double
  ) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 21)
    }
    defer { sqlite3_close(db) }

    let sql = """
      INSERT INTO machine_daily_rollups (date_key, tool, machine_name, total_cost, updated_at)
      VALUES (?, ?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 22)
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (dateKey as NSString).utf8String, -1, nil)
    sqlite3_bind_text(statement, 2, (tool.rawValue as NSString).utf8String, -1, nil)
    sqlite3_bind_text(statement, 3, (machineName as NSString).utf8String, -1, nil)
    sqlite3_bind_double(statement, 4, totalCost)
    sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "UsageStoreTests", code: 23)
    }
  }

  private func updateRawModelSampleDeltas(path: String, deltaCost: Double) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 4)
    }
    defer { sqlite3_close(db) }

    let sql = "UPDATE model_samples SET delta_cost = ?;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 5)
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_double(statement, 1, deltaCost)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "UsageStoreTests", code: 6)
    }
  }

  private func updateRawModelSampleDeltas(path: String, deltaCosts: [Double]) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 11)
    }
    defer { sqlite3_close(db) }

    let selectSQL = "SELECT id FROM model_samples ORDER BY recorded_at ASC;"
    var selectStatement: OpaquePointer?
    guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 12)
    }
    defer { sqlite3_finalize(selectStatement) }

    var ids: [Int32] = []
    while sqlite3_step(selectStatement) == SQLITE_ROW {
      ids.append(sqlite3_column_int(selectStatement, 0))
    }
    guard ids.count == deltaCosts.count else {
      throw NSError(domain: "UsageStoreTests", code: 13)
    }

    let updateSQL = "UPDATE model_samples SET delta_cost = ? WHERE id = ?;"
    var updateStatement: OpaquePointer?
    guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 14)
    }
    defer { sqlite3_finalize(updateStatement) }

    for (id, deltaCost) in zip(ids, deltaCosts) {
      sqlite3_reset(updateStatement)
      sqlite3_clear_bindings(updateStatement)
      sqlite3_bind_double(updateStatement, 1, deltaCost)
      sqlite3_bind_int(updateStatement, 2, id)
      guard sqlite3_step(updateStatement) == SQLITE_DONE else {
        throw NSError(domain: "UsageStoreTests", code: 15)
      }
    }
  }

  private func createLegacyModelSamples(
    path: String,
    samples: [(UsageAgent, String, Date, Double)]
  ) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
    else {
      throw NSError(domain: "UsageStoreTests", code: 7)
    }
    defer { sqlite3_close(db) }

    let createSQL = """
      CREATE TABLE model_samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          model_name TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          total_cost REAL NOT NULL,
          date_key TEXT NOT NULL
      );
      """
    guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 8)
    }

    let insertSQL = """
      INSERT INTO model_samples (tool, model_name, recorded_at, total_cost, date_key)
      VALUES (?, ?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 9)
    }
    defer { sqlite3_finalize(statement) }

    for (tool, modelName, recordedAt, totalCost) in samples {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      sqlite3_bind_text(statement, 1, (tool.rawValue as NSString).utf8String, -1, nil)
      sqlite3_bind_text(statement, 2, (modelName as NSString).utf8String, -1, nil)
      sqlite3_bind_double(statement, 3, recordedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, totalCost)
      sqlite3_bind_text(
        statement, 5, (DateHelper.dateKey(for: recordedAt) as NSString).utf8String, -1, nil)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "UsageStoreTests", code: 10)
      }
    }
  }

  private func createLegacyMachineSamples(
    path: String,
    samples: [(UsageAgent, String, Date, Double)]
  ) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
    else {
      throw NSError(domain: "UsageStoreTests", code: 24)
    }
    defer { sqlite3_close(db) }

    let createSQL = """
      CREATE TABLE machine_samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          machine_name TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          total_cost REAL NOT NULL,
          date_key TEXT NOT NULL
      );
      """
    guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 25)
    }

    let insertSQL = """
      INSERT INTO machine_samples (tool, machine_name, recorded_at, total_cost, date_key)
      VALUES (?, ?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "UsageStoreTests", code: 26)
    }
    defer { sqlite3_finalize(statement) }

    for (tool, machineName, recordedAt, totalCost) in samples {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      sqlite3_bind_text(statement, 1, (tool.rawValue as NSString).utf8String, -1, nil)
      sqlite3_bind_text(statement, 2, (machineName as NSString).utf8String, -1, nil)
      sqlite3_bind_double(statement, 3, recordedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, totalCost)
      sqlite3_bind_text(
        statement, 5, (DateHelper.dateKey(for: recordedAt) as NSString).utf8String, -1, nil)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "UsageStoreTests", code: 27)
      }
    }
  }

  private func temporaryStorePath() -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibepulse-\(UUID().uuidString)")
      .appendingPathExtension("sqlite")
    return url.path
  }
}
