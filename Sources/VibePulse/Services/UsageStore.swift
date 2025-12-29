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
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
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
        if sqlite3_open_v2(path, &dbPointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
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

    func upsertDailyTotals(tool: UsageTool, totals: [DailyTotal]) throws {
        try queue.sync {
            let sql = """
            INSERT INTO daily_rollups (date_key, tool, total_cost, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(date_key, tool) DO UPDATE SET
            total_cost = excluded.total_cost,
            updated_at = excluded.updated_at;
            """
            let updatedAt = Date().timeIntervalSince1970
            for total in totals {
                try withStatement(sql) { statement in
                    bindText(statement, index: 1, value: total.dateKey)
                    bindText(statement, index: 2, value: tool.rawValue)
                    sqlite3_bind_double(statement, 3, total.cost)
                    sqlite3_bind_double(statement, 4, updatedAt)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        throw StoreError.executeFailed(errorMessage)
                    }
                }
            }
        }
    }

    func insertSample(tool: UsageTool, totalCost: Double, recordedAt: Date) throws {
        try queue.sync {
            let sql = """
            INSERT INTO samples (tool, recorded_at, total_cost, delta_cost, date_key)
            VALUES (?, ?, ?, ?, ?);
            """
            let dateKey = DateHelper.dateKey(for: recordedAt)
            let previousTotal = try latestSampleCost(for: dateKey, tool: tool) ?? 0
            let deltaCost = max(0, totalCost - previousTotal)
            try withStatement(sql) { statement in
                bindText(statement, index: 1, value: tool.rawValue)
                sqlite3_bind_double(statement, 2, recordedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 3, totalCost)
                sqlite3_bind_double(statement, 4, deltaCost)
                bindText(statement, index: 5, value: dateKey)
                if sqlite3_step(statement) != SQLITE_DONE {
                    throw StoreError.executeFailed(errorMessage)
                }
            }
        }
    }

    func fetchSamples(tool: UsageTool, from start: Date, to end: Date) -> [UsageSample] {
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
                        results.append(UsageSample(tool: tool, recordedAt: recordedAt, totalCost: totalCost, deltaCost: deltaCost))
                    }
                }
            } catch {
                return []
            }
            return results
        }
    }

    func fetchDailyRollups(since dateKey: String) -> [DailyRollup] {
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
                        guard let normalizedKey = DateHelper.normalizedDateKey(from: rawKey) else {
                            continue
                        }
                        if normalizedKey < dateKey {
                            continue
                        }
                        let toolRaw = String(cString: toolCString)
                        guard let tool = UsageTool(rawValue: toolRaw) else {
                            continue
                        }
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

    func dailyTotal(for dateKey: String, tool: UsageTool) -> Double? {
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

    func latestSample(for dateKey: String, tool: UsageTool) -> UsageSample? {
        queue.sync {
            let sql = """
            SELECT recorded_at, total_cost, delta_cost
            FROM samples
            WHERE date_key = ? AND tool = ?
            ORDER BY recorded_at DESC
            LIMIT 1;
            """
            do {
                return try withStatement(sql) { statement in
                    bindText(statement, index: 1, value: dateKey)
                    bindText(statement, index: 2, value: tool.rawValue)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
                        let totalCost = sqlite3_column_double(statement, 1)
                        let deltaCost = sqlite3_column_double(statement, 2)
                        return UsageSample(tool: tool, recordedAt: recordedAt, totalCost: totalCost, deltaCost: deltaCost)
                    }
                    return nil
                }
            } catch {
                return nil
            }
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
                              let dateKeyCString = sqlite3_column_text(statement, 2) else {
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

    func normalizeDailyRollupDates(for tool: UsageTool) throws -> Int {
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

                        let existingCost = try fetchDailyRollupCost(tool: tool, dateKey: normalizedKey, sql: selectExistingSQL)
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

        try execute(createSamples)
        try execute(createDaily)
        try execute(createSamplesIndex)
        try ensureSampleDeltaColumn()
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

    private func fetchDailyRollupCost(tool: UsageTool, dateKey: String, sql: String) throws -> Double? {
        try withStatement(sql) { statement in
            bindText(statement, index: 1, value: tool.rawValue)
            bindText(statement, index: 2, value: dateKey)
            if sqlite3_step(statement) == SQLITE_ROW {
                return sqlite3_column_double(statement, 0)
            }
            return nil
        }
    }

    private func upsertDailyTotal(tool: UsageTool, dateKey: String, totalCost: Double) throws {
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

    private func latestSampleCost(for dateKey: String, tool: UsageTool) throws -> Double? {
        let sql = """
        SELECT total_cost
        FROM samples
        WHERE date_key = ? AND tool = ?
        ORDER BY recorded_at DESC
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            bindText(statement, index: 1, value: dateKey)
            bindText(statement, index: 2, value: tool.rawValue)
            if sqlite3_step(statement) == SQLITE_ROW {
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
}
