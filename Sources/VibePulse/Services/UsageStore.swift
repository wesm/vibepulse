import Foundation
import SQLite3

final class UsageStore: @unchecked Sendable {
  enum StoreError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
  }

  private let db: OpaquePointer?
  private let queue = DispatchQueue(label: "vibepulse.store")
  private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static func defaultStore() throws -> UsageStore {
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
    let appSupport = baseURL?.appendingPathComponent("VibePulse", isDirectory: true)
    if let appSupport {
      try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
      let dbURL = appSupport.appendingPathComponent("vibepulse.sqlite")
      return try UsageStore(path: dbURL.path)
    }
    return try UsageStore(path: ":memory:")
  }

  init(path: String) throws {
    var dbPointer: OpaquePointer?
    if sqlite3_open_v2(
      path, &dbPointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
      != SQLITE_OK
    {
      let message = String(cString: sqlite3_errmsg(dbPointer))
      sqlite3_close(dbPointer)
      throw StoreError.openFailed(message)
    }
    db = dbPointer
    try migrate()
  }

  deinit {
    sqlite3_close(db)
  }

  func upsertDailyTotals(
    tool: UsageAgent,
    totals: [DailyTotal],
    dateContext: UsageDateContext? = nil
  ) throws {
    let context = dateContext ?? UsageDateContext()
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        let sql = """
          INSERT INTO daily_rollups (date_key, tool, total_cost, updated_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(date_key, tool) DO UPDATE SET
          total_cost = excluded.total_cost,
          updated_at = excluded.updated_at;
          """
        let updatedAt = Date().timeIntervalSince1970
        for total in totals {
          let dateKey =
            DateHelper.normalizedDateKey(from: total.dateKey, in: context.timeZone)
            ?? total.dateKey
          try withStatement(sql) { statement in
            bindText(statement, index: 1, value: dateKey)
            bindText(statement, index: 2, value: tool.rawValue)
            sqlite3_bind_double(statement, 3, total.cost)
            sqlite3_bind_double(statement, 4, updatedAt)
            if sqlite3_step(statement) != SQLITE_DONE {
              throw StoreError.executeFailed(errorMessage)
            }
          }

          if let modelBreakdowns = total.modelBreakdowns {
            try upsertModelDailyTotals(
              tool: tool,
              dateKey: dateKey,
              totals: modelBreakdowns,
              timeZone: context.timeZone)
          }
          if let machineBreakdowns = total.machineBreakdowns {
            try upsertMachineDailyTotals(
              tool: tool,
              dateKey: dateKey,
              totals: machineBreakdowns,
              timeZone: context.timeZone)
          }
        }

        try execute("COMMIT;")
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func insertSample(
    tool: UsageAgent,
    totalCost: Double,
    recordedAt: Date,
    dateContext: UsageDateContext? = nil
  ) throws {
    let context = dateContext ?? UsageDateContext(now: recordedAt)
    try queue.sync {
      let sql = """
        INSERT INTO samples (tool, recorded_at, total_cost, delta_cost, date_key)
        VALUES (?, ?, ?, ?, ?);
        """
      let previousTotal =
        try latestSampleCost(
          for: tool,
          from: context.startOfToday,
          to: context.startOfNextDay) ?? 0
      let deltaCost = max(0, totalCost - previousTotal)
      try withStatement(sql) { statement in
        bindText(statement, index: 1, value: tool.rawValue)
        sqlite3_bind_double(statement, 2, recordedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, totalCost)
        sqlite3_bind_double(statement, 4, deltaCost)
        bindText(statement, index: 5, value: context.todayKey)
        if sqlite3_step(statement) != SQLITE_DONE {
          throw StoreError.executeFailed(errorMessage)
        }
      }
    }
  }

  func fetchSamples(tool: UsageAgent, from start: Date, to end: Date) -> [UsageSample] {
    queue.sync {
      let sql = """
        SELECT recorded_at, total_cost, delta_cost
        FROM samples
        WHERE tool = ? AND recorded_at >= ? AND recorded_at <= ?
        ORDER BY recorded_at ASC;
        """
      var results: [UsageSample] = []
      do {
        try withStatement(sql) { statement in
          bindText(statement, index: 1, value: tool.rawValue)
          sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
          sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
          while sqlite3_step(statement) == SQLITE_ROW {
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let totalCost = sqlite3_column_double(statement, 1)
            let deltaCost = sqlite3_column_double(statement, 2)
            results.append(
              UsageSample(
                tool: tool, recordedAt: recordedAt, totalCost: totalCost, deltaCost: deltaCost))
          }
        }
      } catch {
        return []
      }
      return results
    }
  }

  func storedAgents() -> [UsageAgent] {
    queue.sync {
      let sql = """
        SELECT tool FROM samples
        UNION SELECT tool FROM daily_rollups
        UNION SELECT tool FROM model_samples
        UNION SELECT tool FROM model_daily_rollups;
        """
      var agents = Set<UsageAgent>()
      do {
        try withStatement(sql) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let toolCString = sqlite3_column_text(statement, 0) else { continue }
            let rawValue = String(cString: toolCString)
            guard !rawValue.isEmpty else { continue }
            agents.insert(UsageAgent(rawValue))
          }
        }
      } catch {
        return []
      }
      return agents.sorted()
    }
  }

  func fetchDailyRollups(
    since dateKey: String,
    through endDateKey: String? = nil,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> [DailyRollup] {
    queue.sync {
      let sql = """
        SELECT date_key, tool, total_cost
        FROM daily_rollups;
        """
      var results: [DailyRollup] = []
      do {
        try withStatement(sql) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateKeyCString = sqlite3_column_text(statement, 0),
              let toolCString = sqlite3_column_text(statement, 1)
            else {
              continue
            }
            let rawKey = String(cString: dateKeyCString)
            guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey, in: timeZone)
            else {
              continue
            }
            if normalizedKey < dateKey || normalizedKey > (endDateKey ?? normalizedKey) {
              continue
            }
            let toolRaw = String(cString: toolCString)
            guard !toolRaw.isEmpty else { continue }
            let tool = UsageAgent(toolRaw)
            let totalCost = sqlite3_column_double(statement, 2)
            results.append(DailyRollup(dateKey: normalizedKey, tool: tool, totalCost: totalCost))
          }
        }
      } catch {
        return []
      }
      return results.sorted { $0.dateKey < $1.dateKey }
    }
  }

  func fetchModelDailyRollups(
    since dateKey: String,
    through endDateKey: String? = nil,
    tools: [UsageAgent],
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> [ModelDailyRollup] {
    queue.sync {
      let toolValues = Set(tools.map(\.rawValue))
      let sql = """
        SELECT date_key, tool, model_name, total_cost
        FROM model_daily_rollups;
        """
      var results: [ModelDailyRollup] = []
      do {
        try withStatement(sql) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateKeyCString = sqlite3_column_text(statement, 0),
              let toolCString = sqlite3_column_text(statement, 1),
              let modelNameCString = sqlite3_column_text(statement, 2)
            else {
              continue
            }
            let rawKey = String(cString: dateKeyCString)
            guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey, in: timeZone)
            else {
              continue
            }
            if normalizedKey < dateKey || normalizedKey > (endDateKey ?? normalizedKey) {
              continue
            }
            let toolRaw = String(cString: toolCString)
            guard toolValues.contains(toolRaw), !toolRaw.isEmpty else { continue }
            let tool = UsageAgent(toolRaw)
            let modelName = String(cString: modelNameCString)
            let totalCost = sqlite3_column_double(statement, 3)
            results.append(
              ModelDailyRollup(
                dateKey: normalizedKey,
                tool: tool,
                modelName: modelName,
                totalCost: totalCost))
          }
        }
      } catch {
        return []
      }
      return results.sorted {
        if $0.dateKey == $1.dateKey {
          if $0.modelName == $1.modelName {
            return $0.tool < $1.tool
          }
          return $0.modelName < $1.modelName
        }
        return $0.dateKey < $1.dateKey
      }
    }
  }

  func fetchMachineDailyRollups(
    since dateKey: String,
    through endDateKey: String? = nil,
    tools: [UsageAgent],
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> [MachineDailyRollup] {
    queue.sync {
      let allowedTools = Set(tools)
      let sql = """
        SELECT date_key, tool, machine_name, total_cost
        FROM machine_daily_rollups;
        """
      var results: [MachineDailyRollup] = []
      do {
        try withStatement(sql) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            guard
              let dateCString = sqlite3_column_text(statement, 0),
              let toolCString = sqlite3_column_text(statement, 1),
              let machineNameCString = sqlite3_column_text(statement, 2)
            else {
              continue
            }
            let rawKey = String(cString: dateCString)
            guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey, in: timeZone)
            else {
              continue
            }
            if normalizedKey < dateKey || normalizedKey > (endDateKey ?? normalizedKey) {
              continue
            }
            let toolRaw = String(cString: toolCString)
            guard !toolRaw.isEmpty else { continue }
            let tool = UsageAgent(toolRaw)
            guard allowedTools.contains(tool) else { continue }
            let machineName = String(cString: machineNameCString)
            let totalCost = sqlite3_column_double(statement, 3)
            results.append(
              MachineDailyRollup(
                dateKey: normalizedKey,
                tool: tool,
                machineName: machineName,
                totalCost: totalCost))
          }
        }
      } catch {
        return []
      }
      return results.sorted {
        if $0.dateKey == $1.dateKey {
          if $0.machineName == $1.machineName {
            return $0.tool.rawValue < $1.tool.rawValue
          }
          return $0.machineName < $1.machineName
        }
        return $0.dateKey < $1.dateKey
      }
    }
  }

  func dailyTotal(for dateKey: String, tool: UsageAgent) -> Double? {
    queue.sync {
      let sql = """
        SELECT total_cost
        FROM daily_rollups
        WHERE date_key = ? AND tool = ?
        LIMIT 1;
        """
      do {
        return try withStatement(sql) { statement in
          bindText(statement, index: 1, value: dateKey)
          bindText(statement, index: 2, value: tool.rawValue)
          if sqlite3_step(statement) == SQLITE_ROW {
            return sqlite3_column_double(statement, 0)
          }
          return nil
        }
      } catch {
        return nil
      }
    }
  }

  func latestSample(tool: UsageAgent, from start: Date, to end: Date) -> UsageSample? {
    queue.sync {
      let sql = """
        SELECT recorded_at, total_cost, delta_cost
        FROM samples
        WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?
        ORDER BY recorded_at DESC
        LIMIT 1;
        """
      do {
        return try withStatement(sql) { statement in
          bindText(statement, index: 1, value: tool.rawValue)
          sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
          sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
          if sqlite3_step(statement) == SQLITE_ROW {
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let totalCost = sqlite3_column_double(statement, 1)
            let deltaCost = sqlite3_column_double(statement, 2)
            return UsageSample(
              tool: tool, recordedAt: recordedAt, totalCost: totalCost, deltaCost: deltaCost)
          }
          return nil
        }
      } catch {
        return nil
      }
    }
  }

  func deleteCurrentDaySamples(using context: UsageDateContext) throws {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        for table in ["samples", "model_samples", "machine_samples"] {
          let sql = """
            DELETE FROM \(table)
            WHERE recorded_at >= ? AND recorded_at < ?;
            """
          try withStatement(sql) { statement in
            sqlite3_bind_double(statement, 1, context.startOfToday.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, context.startOfNextDay.timeIntervalSince1970)
            if sqlite3_step(statement) != SQLITE_DONE {
              throw StoreError.executeFailed(errorMessage)
            }
          }
        }
        try execute("COMMIT;")
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func insertModelSample(
    tool: UsageAgent,
    modelName: String,
    totalCost: Double,
    recordedAt: Date,
    dateContext: UsageDateContext? = nil
  ) throws {
    let context = dateContext ?? UsageDateContext(now: recordedAt)
    try queue.sync {
      try insertModelSampleInCurrentQueue(
        tool: tool,
        modelName: modelName,
        totalCost: totalCost,
        recordedAt: recordedAt,
        dateContext: context)
    }
  }

  func insertModelSamplesForRefresh(
    tool: UsageAgent,
    modelBreakdowns: [DailyModelBreakdown],
    recordedAt: Date,
    dateContext: UsageDateContext? = nil
  ) throws {
    let context = dateContext ?? UsageDateContext(now: recordedAt)
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        let currentTotals = Dictionary(
          modelBreakdowns.map { ($0.modelName, $0.cost) },
          uniquingKeysWith: { _, new in new })
        let previousModels = try modelSampleNames(
          for: tool,
          from: context.startOfToday,
          to: context.startOfNextDay)
        let modelNames = Set(currentTotals.keys).union(previousModels).sorted()

        for modelName in modelNames {
          try insertModelSampleInCurrentQueue(
            tool: tool,
            modelName: modelName,
            totalCost: currentTotals[modelName] ?? 0,
            recordedAt: recordedAt,
            dateContext: context)
        }

        try execute("COMMIT;")
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func fetchModelSamples(tools: [UsageAgent], from start: Date, to end: Date) -> [ModelUsageSample]
  {
    queue.sync {
      let toolValues = Set(tools.map(\.rawValue))
      let sql = """
        SELECT tool, model_name, recorded_at, total_cost, delta_cost
        FROM model_samples
        WHERE recorded_at >= ? AND recorded_at <= ?
        ORDER BY recorded_at ASC, model_name ASC, tool ASC;
        """
      var results: [ModelUsageSample] = []
      do {
        try withStatement(sql) { statement in
          sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
          sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let toolCString = sqlite3_column_text(statement, 0),
              let modelNameCString = sqlite3_column_text(statement, 1)
            else {
              continue
            }
            let toolRaw = String(cString: toolCString)
            guard toolValues.contains(toolRaw), !toolRaw.isEmpty else { continue }
            let tool = UsageAgent(toolRaw)
            let modelName = String(cString: modelNameCString)
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let totalCost = sqlite3_column_double(statement, 3)
            let deltaCost = sqlite3_column_double(statement, 4)
            results.append(
              ModelUsageSample(
                tool: tool,
                modelName: modelName,
                recordedAt: recordedAt,
                totalCost: totalCost,
                deltaCost: deltaCost))
          }
        }
      } catch {
        return []
      }
      return results
    }
  }

  func insertMachineSample(
    tool: UsageAgent,
    machineName: String,
    totalCost: Double,
    recordedAt: Date,
    dateContext: UsageDateContext? = nil
  ) throws {
    let context = dateContext ?? UsageDateContext(now: recordedAt)
    try queue.sync {
      try insertMachineSampleInCurrentQueue(
        tool: tool,
        machineName: machineName,
        totalCost: totalCost,
        recordedAt: recordedAt,
        dateContext: context)
    }
  }

  func insertMachineSamplesForRefresh(
    tool: UsageAgent,
    machineBreakdowns: [DailyMachineBreakdown],
    recordedAt: Date,
    dateContext: UsageDateContext? = nil
  ) throws {
    let context = dateContext ?? UsageDateContext(now: recordedAt)
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        let currentTotals = Dictionary(
          machineBreakdowns.map { ($0.machineName, $0.cost) },
          uniquingKeysWith: { _, new in new })
        let previousMachines = try machineSampleNames(
          for: tool,
          from: context.startOfToday,
          to: context.startOfNextDay)
        let machineNames = Set(currentTotals.keys).union(previousMachines).sorted()

        for machineName in machineNames {
          try insertMachineSampleInCurrentQueue(
            tool: tool,
            machineName: machineName,
            totalCost: currentTotals[machineName] ?? 0,
            recordedAt: recordedAt,
            dateContext: context)
        }

        try execute("COMMIT;")
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func fetchMachineSamples(
    tools: [UsageAgent], from start: Date, to end: Date
  ) -> [MachineUsageSample] {
    queue.sync {
      let toolValues = Set(tools.map(\.rawValue))
      let sql = """
        SELECT tool, machine_name, recorded_at, total_cost, delta_cost
        FROM machine_samples
        WHERE recorded_at >= ? AND recorded_at <= ?
        ORDER BY recorded_at ASC, machine_name ASC, tool ASC;
        """
      var results: [MachineUsageSample] = []
      do {
        try withStatement(sql) { statement in
          sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
          sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let toolCString = sqlite3_column_text(statement, 0),
              let machineNameCString = sqlite3_column_text(statement, 1)
            else {
              continue
            }
            let toolRaw = String(cString: toolCString)
            guard toolValues.contains(toolRaw), !toolRaw.isEmpty else {
              continue
            }
            let tool = UsageAgent(toolRaw)
            let machineName = String(cString: machineNameCString)
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let totalCost = sqlite3_column_double(statement, 3)
            let deltaCost = sqlite3_column_double(statement, 4)
            results.append(
              MachineUsageSample(
                tool: tool,
                machineName: machineName,
                recordedAt: recordedAt,
                totalCost: totalCost,
                deltaCost: deltaCost))
          }
        }
      } catch {
        return []
      }
      return results
    }
  }

  func backfillSampleDeltas() throws -> Int {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        let selectSQL = """
          SELECT id, tool, date_key, total_cost, delta_cost
          FROM samples
          ORDER BY tool, date_key, recorded_at ASC;
          """

        let updateSQL = "UPDATE samples SET delta_cost = ? WHERE id = ?;"

        var updatedCount = 0
        var previousTool: String?
        var previousDateKey: String?
        var previousTotal: Double = 0

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(updateStatement) }

        try withStatement(selectSQL) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            let sampleId = sqlite3_column_int(statement, 0)
            guard let toolCString = sqlite3_column_text(statement, 1),
              let dateKeyCString = sqlite3_column_text(statement, 2)
            else {
              continue
            }
            let toolRaw = String(cString: toolCString)
            let dateKey = String(cString: dateKeyCString)
            let totalCost = sqlite3_column_double(statement, 3)
            let existingDelta = sqlite3_column_double(statement, 4)

            if toolRaw != previousTool || dateKey != previousDateKey {
              previousTool = toolRaw
              previousDateKey = dateKey
              previousTotal = 0
            }

            let newDelta = max(0, totalCost - previousTotal)
            if abs(newDelta - existingDelta) > 0.0001 {
              sqlite3_reset(updateStatement)
              sqlite3_clear_bindings(updateStatement)
              sqlite3_bind_double(updateStatement, 1, newDelta)
              sqlite3_bind_int(updateStatement, 2, sampleId)
              if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
              updatedCount += 1
            }

            previousTotal = totalCost
          }
        }

        try execute("COMMIT;")
        return updatedCount
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func backfillModelSampleDeltas() throws -> Int {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        let selectSQL = """
          SELECT id, tool, model_name, date_key, total_cost, delta_cost
          FROM model_samples
          ORDER BY tool, model_name, date_key, recorded_at ASC;
          """

        let updateSQL = "UPDATE model_samples SET delta_cost = ? WHERE id = ?;"

        var updatedCount = 0
        var previousTool: String?
        var previousModelName: String?
        var previousDateKey: String?
        var previousMaxTotal: Double = 0

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(updateStatement) }

        try withStatement(selectSQL) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            let sampleId = sqlite3_column_int(statement, 0)
            guard let toolCString = sqlite3_column_text(statement, 1),
              let modelNameCString = sqlite3_column_text(statement, 2),
              let dateKeyCString = sqlite3_column_text(statement, 3)
            else {
              continue
            }
            let toolRaw = String(cString: toolCString)
            let modelName = String(cString: modelNameCString)
            let dateKey = String(cString: dateKeyCString)
            let totalCost = sqlite3_column_double(statement, 4)
            let existingDelta = sqlite3_column_double(statement, 5)

            if toolRaw != previousTool || modelName != previousModelName
              || dateKey != previousDateKey
            {
              previousTool = toolRaw
              previousModelName = modelName
              previousDateKey = dateKey
              previousMaxTotal = 0
            }

            let newDelta = max(0, totalCost - previousMaxTotal)
            if abs(newDelta - existingDelta) > 0.0001 {
              sqlite3_reset(updateStatement)
              sqlite3_clear_bindings(updateStatement)
              sqlite3_bind_double(updateStatement, 1, newDelta)
              sqlite3_bind_int(updateStatement, 2, sampleId)
              if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
              updatedCount += 1
            }

            previousMaxTotal = max(previousMaxTotal, totalCost)
          }
        }

        try execute("COMMIT;")
        return updatedCount
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func backfillMachineSampleDeltas() throws -> Int {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        let selectSQL = """
          SELECT id, tool, machine_name, date_key, total_cost, delta_cost
          FROM machine_samples
          ORDER BY tool, machine_name, date_key, recorded_at ASC;
          """
        let updateSQL = "UPDATE machine_samples SET delta_cost = ? WHERE id = ?;"

        var updatedCount = 0
        var previousTool: String?
        var previousMachineName: String?
        var previousDateKey: String?
        var previousMaxTotal: Double = 0

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(updateStatement) }

        try withStatement(selectSQL) { statement in
          while sqlite3_step(statement) == SQLITE_ROW {
            let sampleId = sqlite3_column_int(statement, 0)
            guard let toolCString = sqlite3_column_text(statement, 1),
              let machineNameCString = sqlite3_column_text(statement, 2),
              let dateKeyCString = sqlite3_column_text(statement, 3)
            else {
              continue
            }
            let toolRaw = String(cString: toolCString)
            let machineName = String(cString: machineNameCString)
            let dateKey = String(cString: dateKeyCString)
            let totalCost = sqlite3_column_double(statement, 4)
            let existingDelta = sqlite3_column_double(statement, 5)

            if toolRaw != previousTool || machineName != previousMachineName
              || dateKey != previousDateKey
            {
              previousTool = toolRaw
              previousMachineName = machineName
              previousDateKey = dateKey
              previousMaxTotal = 0
            }

            let newDelta = max(0, totalCost - previousMaxTotal)
            if abs(newDelta - existingDelta) > 0.0001 {
              sqlite3_reset(updateStatement)
              sqlite3_clear_bindings(updateStatement)
              sqlite3_bind_double(updateStatement, 1, newDelta)
              sqlite3_bind_int(updateStatement, 2, sampleId)
              if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
              updatedCount += 1
            }

            previousMaxTotal = max(previousMaxTotal, totalCost)
          }
        }

        try execute("COMMIT;")
        return updatedCount
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func normalizeDailyRollupDates(for tool: UsageAgent) throws -> Int {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        let selectSQL = """
          SELECT date_key, total_cost
          FROM daily_rollups
          WHERE tool = ?;
          """
        let updateSQL = """
          UPDATE daily_rollups
          SET date_key = ?
          WHERE tool = ? AND date_key = ?;
          """
        let deleteSQL = """
          DELETE FROM daily_rollups
          WHERE tool = ? AND date_key = ?;
          """
        let selectExistingSQL = """
          SELECT total_cost
          FROM daily_rollups
          WHERE tool = ? AND date_key = ?
          LIMIT 1;
          """

        var updatedCount = 0

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        guard let updateStatement else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(updateStatement) }

        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        guard let deleteStatement else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(deleteStatement) }

        try withStatement(selectSQL) { statement in
          bindText(statement, index: 1, value: tool.rawValue)
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateKeyCString = sqlite3_column_text(statement, 0) else {
              continue
            }
            let rawKey = String(cString: dateKeyCString)
            let totalCost = sqlite3_column_double(statement, 1)
            guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey) else {
              continue
            }
            if normalizedKey == rawKey {
              continue
            }

            let existingCost = try fetchDailyRollupCost(
              tool: tool, dateKey: normalizedKey, sql: selectExistingSQL)
            if let existingCost {
              let merged = max(existingCost, totalCost)
              if abs(merged - existingCost) > 0.0001 {
                try upsertDailyTotal(tool: tool, dateKey: normalizedKey, totalCost: merged)
              }
              sqlite3_reset(deleteStatement)
              sqlite3_clear_bindings(deleteStatement)
              bindText(deleteStatement, index: 1, value: tool.rawValue)
              bindText(deleteStatement, index: 2, value: rawKey)
              if sqlite3_step(deleteStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
            } else {
              sqlite3_reset(updateStatement)
              sqlite3_clear_bindings(updateStatement)
              bindText(updateStatement, index: 1, value: normalizedKey)
              bindText(updateStatement, index: 2, value: tool.rawValue)
              bindText(updateStatement, index: 3, value: rawKey)
              if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
            }
            updatedCount += 1
          }
        }

        try execute("COMMIT;")
        return updatedCount
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func normalizeModelDailyRollupDates(for tool: UsageAgent) throws -> Int {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        let selectSQL = """
          SELECT date_key, model_name, total_cost
          FROM model_daily_rollups
          WHERE tool = ?;
          """
        let updateSQL = """
          UPDATE model_daily_rollups
          SET date_key = ?
          WHERE tool = ? AND date_key = ? AND model_name = ?;
          """
        let deleteSQL = """
          DELETE FROM model_daily_rollups
          WHERE tool = ? AND date_key = ? AND model_name = ?;
          """
        let selectExistingSQL = """
          SELECT total_cost
          FROM model_daily_rollups
          WHERE tool = ? AND date_key = ? AND model_name = ?
          LIMIT 1;
          """

        var updatedCount = 0

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        guard let updateStatement else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(updateStatement) }

        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
          throw StoreError.prepareFailed(errorMessage)
        }
        guard let deleteStatement else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(deleteStatement) }

        try withStatement(selectSQL) { statement in
          bindText(statement, index: 1, value: tool.rawValue)
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateKeyCString = sqlite3_column_text(statement, 0),
              let modelNameCString = sqlite3_column_text(statement, 1)
            else {
              continue
            }
            let rawKey = String(cString: dateKeyCString)
            let modelName = String(cString: modelNameCString)
            let totalCost = sqlite3_column_double(statement, 2)
            guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey) else {
              continue
            }
            if normalizedKey == rawKey {
              continue
            }

            let existingCost = try fetchModelDailyRollupCost(
              tool: tool,
              dateKey: normalizedKey,
              modelName: modelName,
              sql: selectExistingSQL)
            if let existingCost {
              let merged = max(existingCost, totalCost)
              if abs(merged - existingCost) > 0.0001 {
                try upsertModelDailyTotal(
                  tool: tool,
                  dateKey: normalizedKey,
                  modelName: modelName,
                  totalCost: merged)
              }
              sqlite3_reset(deleteStatement)
              sqlite3_clear_bindings(deleteStatement)
              bindText(deleteStatement, index: 1, value: tool.rawValue)
              bindText(deleteStatement, index: 2, value: rawKey)
              bindText(deleteStatement, index: 3, value: modelName)
              if sqlite3_step(deleteStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
            } else {
              sqlite3_reset(updateStatement)
              sqlite3_clear_bindings(updateStatement)
              bindText(updateStatement, index: 1, value: normalizedKey)
              bindText(updateStatement, index: 2, value: tool.rawValue)
              bindText(updateStatement, index: 3, value: rawKey)
              bindText(updateStatement, index: 4, value: modelName)
              if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
            }
            updatedCount += 1
          }
        }

        try execute("COMMIT;")
        return updatedCount
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  func normalizeMachineDailyRollupDates(for tool: UsageAgent) throws -> Int {
    try queue.sync {
      do {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        let selectSQL = """
          SELECT date_key, machine_name, total_cost
          FROM machine_daily_rollups
          WHERE tool = ?;
          """
        let updateSQL = """
          UPDATE machine_daily_rollups
          SET date_key = ?
          WHERE tool = ? AND date_key = ? AND machine_name = ?;
          """
        let deleteSQL = """
          DELETE FROM machine_daily_rollups
          WHERE tool = ? AND date_key = ? AND machine_name = ?;
          """
        let selectExistingSQL = """
          SELECT total_cost
          FROM machine_daily_rollups
          WHERE tool = ? AND date_key = ? AND machine_name = ?
          LIMIT 1;
          """

        var updatedCount = 0
        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK,
          let updateStatement
        else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(updateStatement) }

        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK,
          let deleteStatement
        else {
          throw StoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(deleteStatement) }

        try withStatement(selectSQL) { statement in
          bindText(statement, index: 1, value: tool.rawValue)
          while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateKeyCString = sqlite3_column_text(statement, 0),
              let machineNameCString = sqlite3_column_text(statement, 1)
            else {
              continue
            }
            let rawKey = String(cString: dateKeyCString)
            let machineName = String(cString: machineNameCString)
            let totalCost = sqlite3_column_double(statement, 2)
            guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey),
              normalizedKey != rawKey
            else {
              continue
            }

            let existingCost = try fetchMachineDailyRollupCost(
              tool: tool,
              dateKey: normalizedKey,
              machineName: machineName,
              sql: selectExistingSQL)
            if let existingCost {
              let merged = max(existingCost, totalCost)
              if abs(merged - existingCost) > 0.0001 {
                try upsertMachineDailyTotal(
                  tool: tool,
                  dateKey: normalizedKey,
                  machineName: machineName,
                  totalCost: merged)
              }
              sqlite3_reset(deleteStatement)
              sqlite3_clear_bindings(deleteStatement)
              bindText(deleteStatement, index: 1, value: tool.rawValue)
              bindText(deleteStatement, index: 2, value: rawKey)
              bindText(deleteStatement, index: 3, value: machineName)
              if sqlite3_step(deleteStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
            } else {
              sqlite3_reset(updateStatement)
              sqlite3_clear_bindings(updateStatement)
              bindText(updateStatement, index: 1, value: normalizedKey)
              bindText(updateStatement, index: 2, value: tool.rawValue)
              bindText(updateStatement, index: 3, value: rawKey)
              bindText(updateStatement, index: 4, value: machineName)
              if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw StoreError.executeFailed(errorMessage)
              }
            }
            updatedCount += 1
          }
        }

        try execute("COMMIT;")
        return updatedCount
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  private func migrate() throws {
    let createSamples = """
      CREATE TABLE IF NOT EXISTS samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          total_cost REAL NOT NULL,
          delta_cost REAL NOT NULL DEFAULT 0,
          date_key TEXT NOT NULL
      );
      """

    let createDaily = """
      CREATE TABLE IF NOT EXISTS daily_rollups (
          date_key TEXT NOT NULL,
          tool TEXT NOT NULL,
          total_cost REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (date_key, tool)
      );
      """

    let createSamplesIndex = """
      CREATE INDEX IF NOT EXISTS idx_samples_date_tool
      ON samples (date_key, tool);
      """

    let createModelDaily = """
      CREATE TABLE IF NOT EXISTS model_daily_rollups (
          date_key TEXT NOT NULL,
          tool TEXT NOT NULL,
          model_name TEXT NOT NULL,
          total_cost REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (date_key, tool, model_name)
      );
      """

    let createModelSamples = """
      CREATE TABLE IF NOT EXISTS model_samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          model_name TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          total_cost REAL NOT NULL,
          delta_cost REAL NOT NULL DEFAULT 0,
          date_key TEXT NOT NULL
      );
      """

    let createModelSamplesIndex = """
      CREATE INDEX IF NOT EXISTS idx_model_samples_date_tool_model
      ON model_samples (date_key, tool, model_name);
      """

    let createMachineDaily = """
      CREATE TABLE IF NOT EXISTS machine_daily_rollups (
          date_key TEXT NOT NULL,
          tool TEXT NOT NULL,
          machine_name TEXT NOT NULL,
          total_cost REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (date_key, tool, machine_name)
      );
      """

    let createMachineSamples = """
      CREATE TABLE IF NOT EXISTS machine_samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tool TEXT NOT NULL,
          machine_name TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          total_cost REAL NOT NULL,
          delta_cost REAL NOT NULL DEFAULT 0,
          date_key TEXT NOT NULL
      );
      """

    let createMachineSamplesIndex = """
      CREATE INDEX IF NOT EXISTS idx_machine_samples_date_tool_machine
      ON machine_samples (date_key, tool, machine_name);
      """

    try execute(createSamples)
    try execute(createDaily)
    try execute(createSamplesIndex)
    try execute(createModelDaily)
    try execute(createModelSamples)
    try execute(createModelSamplesIndex)
    try execute(createMachineDaily)
    try execute(createMachineSamples)
    try execute(createMachineSamplesIndex)
    try ensureSampleDeltaColumn()
    if try ensureModelSampleDeltaColumn() {
      _ = try backfillModelSampleDeltas()
    }
    if try ensureMachineSampleDeltaColumn() {
      _ = try backfillMachineSampleDeltas()
    }
  }

  private func execute(_ sql: String) throws {
    var errorMessagePointer: UnsafeMutablePointer<Int8>?
    if sqlite3_exec(db, sql, nil, nil, &errorMessagePointer) != SQLITE_OK {
      let message = errorMessagePointer.map { String(cString: $0) } ?? errorMessage
      sqlite3_free(errorMessagePointer)
      throw StoreError.executeFailed(message)
    }
  }

  private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw StoreError.prepareFailed(errorMessage)
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement!)
  }

  private var errorMessage: String {
    guard let db else { return "Unknown SQLite error" }
    return String(cString: sqlite3_errmsg(db))
  }

  private func bindText(_ statement: OpaquePointer, index: Int32, value: String) {
    sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
  }

  private func fetchDailyRollupCost(tool: UsageAgent, dateKey: String, sql: String) throws
    -> Double?
  {
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: dateKey)
      if sqlite3_step(statement) == SQLITE_ROW {
        return sqlite3_column_double(statement, 0)
      }
      return nil
    }
  }

  private func fetchModelDailyRollupCost(
    tool: UsageAgent,
    dateKey: String,
    modelName: String,
    sql: String
  ) throws -> Double? {
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: dateKey)
      bindText(statement, index: 3, value: modelName)
      if sqlite3_step(statement) == SQLITE_ROW {
        return sqlite3_column_double(statement, 0)
      }
      return nil
    }
  }

  private func fetchMachineDailyRollupCost(
    tool: UsageAgent,
    dateKey: String,
    machineName: String,
    sql: String
  ) throws -> Double? {
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: dateKey)
      bindText(statement, index: 3, value: machineName)
      if sqlite3_step(statement) == SQLITE_ROW {
        return sqlite3_column_double(statement, 0)
      }
      return nil
    }
  }

  private func upsertDailyTotal(tool: UsageAgent, dateKey: String, totalCost: Double) throws {
    let sql = """
      INSERT INTO daily_rollups (date_key, tool, total_cost, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(date_key, tool) DO UPDATE SET
      total_cost = excluded.total_cost,
      updated_at = excluded.updated_at;
      """
    let updatedAt = Date().timeIntervalSince1970
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: dateKey)
      bindText(statement, index: 2, value: tool.rawValue)
      sqlite3_bind_double(statement, 3, totalCost)
      sqlite3_bind_double(statement, 4, updatedAt)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
  }

  private func upsertModelDailyTotal(
    tool: UsageAgent,
    dateKey: String,
    modelName: String,
    totalCost: Double
  ) throws {
    let sql = """
      INSERT INTO model_daily_rollups (date_key, tool, model_name, total_cost, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(date_key, tool, model_name) DO UPDATE SET
      total_cost = excluded.total_cost,
      updated_at = excluded.updated_at;
      """
    let updatedAt = Date().timeIntervalSince1970
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: dateKey)
      bindText(statement, index: 2, value: tool.rawValue)
      bindText(statement, index: 3, value: modelName)
      sqlite3_bind_double(statement, 4, totalCost)
      sqlite3_bind_double(statement, 5, updatedAt)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
  }

  private func upsertModelDailyTotals(
    tool: UsageAgent,
    dateKey: String,
    totals: [DailyModelBreakdown],
    timeZone: TimeZone
  ) throws {
    let normalizedDateKey =
      DateHelper.normalizedDateKey(from: dateKey, in: timeZone) ?? dateKey
    let deleteSQL = """
      DELETE FROM model_daily_rollups
      WHERE date_key = ? AND tool = ?;
      """
    try withStatement(deleteSQL) { statement in
      bindText(statement, index: 1, value: normalizedDateKey)
      bindText(statement, index: 2, value: tool.rawValue)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
    for total in totals {
      try upsertModelDailyTotal(
        tool: tool,
        dateKey: normalizedDateKey,
        modelName: total.modelName,
        totalCost: total.cost)
    }
  }

  private func upsertMachineDailyTotal(
    tool: UsageAgent,
    dateKey: String,
    machineName: String,
    totalCost: Double
  ) throws {
    let sql = """
      INSERT INTO machine_daily_rollups (date_key, tool, machine_name, total_cost, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(date_key, tool, machine_name) DO UPDATE SET
      total_cost = excluded.total_cost,
      updated_at = excluded.updated_at;
      """
    let updatedAt = Date().timeIntervalSince1970
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: dateKey)
      bindText(statement, index: 2, value: tool.rawValue)
      bindText(statement, index: 3, value: machineName)
      sqlite3_bind_double(statement, 4, totalCost)
      sqlite3_bind_double(statement, 5, updatedAt)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
  }

  private func upsertMachineDailyTotals(
    tool: UsageAgent,
    dateKey: String,
    totals: [DailyMachineBreakdown],
    timeZone: TimeZone
  ) throws {
    let normalizedDateKey =
      DateHelper.normalizedDateKey(from: dateKey, in: timeZone) ?? dateKey
    let deleteSQL = """
      DELETE FROM machine_daily_rollups
      WHERE date_key = ? AND tool = ?;
      """
    try withStatement(deleteSQL) { statement in
      bindText(statement, index: 1, value: normalizedDateKey)
      bindText(statement, index: 2, value: tool.rawValue)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
    for total in totals {
      try upsertMachineDailyTotal(
        tool: tool,
        dateKey: normalizedDateKey,
        machineName: total.machineName,
        totalCost: total.cost)
    }
  }

  private func insertModelSampleInCurrentQueue(
    tool: UsageAgent,
    modelName: String,
    totalCost: Double,
    recordedAt: Date,
    dateContext: UsageDateContext
  ) throws {
    let sql = """
        INSERT INTO model_samples (tool, model_name, recorded_at, total_cost, delta_cost, date_key)
        VALUES (?, ?, ?, ?, ?, ?);
      """
    let previousTotal =
      try maxModelSampleCost(
        tool: tool,
        modelName: modelName,
        from: dateContext.startOfToday,
        to: dateContext.startOfNextDay) ?? 0
    let deltaCost = max(0, totalCost - previousTotal)
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: modelName)
      sqlite3_bind_double(statement, 3, recordedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, totalCost)
      sqlite3_bind_double(statement, 5, deltaCost)
      bindText(statement, index: 6, value: dateContext.todayKey)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
  }

  private func modelSampleNames(
    for tool: UsageAgent,
    from start: Date,
    to end: Date
  ) throws -> Set<String> {
    let sql = """
      SELECT DISTINCT model_name
      FROM model_samples
      WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?;
      """
    var modelNames = Set<String>()
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let modelNameCString = sqlite3_column_text(statement, 0) else {
          continue
        }
        modelNames.insert(String(cString: modelNameCString))
      }
    }
    return modelNames
  }

  private func insertMachineSampleInCurrentQueue(
    tool: UsageAgent,
    machineName: String,
    totalCost: Double,
    recordedAt: Date,
    dateContext: UsageDateContext
  ) throws {
    let sql = """
        INSERT INTO machine_samples (
          tool, machine_name, recorded_at, total_cost, delta_cost, date_key
        ) VALUES (?, ?, ?, ?, ?, ?);
      """
    let previousTotal =
      try maxMachineSampleCost(
        tool: tool,
        machineName: machineName,
        from: dateContext.startOfToday,
        to: dateContext.startOfNextDay) ?? 0
    let deltaCost = max(0, totalCost - previousTotal)
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: machineName)
      sqlite3_bind_double(statement, 3, recordedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, totalCost)
      sqlite3_bind_double(statement, 5, deltaCost)
      bindText(statement, index: 6, value: dateContext.todayKey)
      if sqlite3_step(statement) != SQLITE_DONE {
        throw StoreError.executeFailed(errorMessage)
      }
    }
  }

  private func machineSampleNames(
    for tool: UsageAgent,
    from start: Date,
    to end: Date
  ) throws -> Set<String> {
    let sql = """
      SELECT DISTINCT machine_name
      FROM machine_samples
      WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?;
      """
    var machineNames = Set<String>()
    try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let machineNameCString = sqlite3_column_text(statement, 0) else {
          continue
        }
        machineNames.insert(String(cString: machineNameCString))
      }
    }
    return machineNames
  }

  private func latestSampleCost(
    for tool: UsageAgent,
    from start: Date,
    to end: Date
  ) throws -> Double? {
    let sql = """
      SELECT total_cost
      FROM samples
      WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?
      ORDER BY recorded_at DESC
      LIMIT 1;
      """
    return try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
      if sqlite3_step(statement) == SQLITE_ROW {
        return sqlite3_column_double(statement, 0)
      }
      return nil
    }
  }

  private func maxModelSampleCost(
    tool: UsageAgent,
    modelName: String,
    from start: Date,
    to end: Date
  ) throws -> Double? {
    let sql = """
      SELECT MAX(total_cost)
      FROM model_samples
      WHERE tool = ? AND model_name = ? AND recorded_at >= ? AND recorded_at < ?
      """
    return try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: modelName)
      sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, end.timeIntervalSince1970)
      if sqlite3_step(statement) == SQLITE_ROW {
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
          return nil
        }
        return sqlite3_column_double(statement, 0)
      }
      return nil
    }
  }

  private func maxMachineSampleCost(
    tool: UsageAgent,
    machineName: String,
    from start: Date,
    to end: Date
  ) throws -> Double? {
    let sql = """
      SELECT MAX(total_cost)
      FROM machine_samples
      WHERE tool = ? AND machine_name = ? AND recorded_at >= ? AND recorded_at < ?
      """
    return try withStatement(sql) { statement in
      bindText(statement, index: 1, value: tool.rawValue)
      bindText(statement, index: 2, value: machineName)
      sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, end.timeIntervalSince1970)
      if sqlite3_step(statement) == SQLITE_ROW {
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
          return nil
        }
        return sqlite3_column_double(statement, 0)
      }
      return nil
    }
  }

  private func ensureSampleDeltaColumn() throws {
    let sql = "PRAGMA table_info(samples);"
    var hasDelta = false
    try withStatement(sql) { statement in
      while sqlite3_step(statement) == SQLITE_ROW {
        if let nameCString = sqlite3_column_text(statement, 1) {
          let name = String(cString: nameCString)
          if name == "delta_cost" {
            hasDelta = true
            break
          }
        }
      }
    }
    if !hasDelta {
      try execute("ALTER TABLE samples ADD COLUMN delta_cost REAL NOT NULL DEFAULT 0;")
    }
  }

  private func ensureModelSampleDeltaColumn() throws -> Bool {
    let sql = "PRAGMA table_info(model_samples);"
    var hasDelta = false
    try withStatement(sql) { statement in
      while sqlite3_step(statement) == SQLITE_ROW {
        if let nameCString = sqlite3_column_text(statement, 1) {
          let name = String(cString: nameCString)
          if name == "delta_cost" {
            hasDelta = true
            break
          }
        }
      }
    }
    if !hasDelta {
      try execute("ALTER TABLE model_samples ADD COLUMN delta_cost REAL NOT NULL DEFAULT 0;")
      return true
    }
    return false
  }

  private func ensureMachineSampleDeltaColumn() throws -> Bool {
    let sql = "PRAGMA table_info(machine_samples);"
    var hasDelta = false
    try withStatement(sql) { statement in
      while sqlite3_step(statement) == SQLITE_ROW {
        if let nameCString = sqlite3_column_text(statement, 1),
          String(cString: nameCString) == "delta_cost"
        {
          hasDelta = true
          break
        }
      }
    }
    if !hasDelta {
      try execute("ALTER TABLE machine_samples ADD COLUMN delta_cost REAL NOT NULL DEFAULT 0;")
      return true
    }
    return false
  }
}
