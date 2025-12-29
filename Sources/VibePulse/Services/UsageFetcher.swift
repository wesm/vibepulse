import Foundation

final class UsageFetcher: @unchecked Sendable {
    enum FetchError: Error {
        case commandFailed(String)
        case invalidOutput
    }

    func fetchDailyTotals(for tool: UsageTool) throws -> [DailyTotal] {
        let data = try runCommand(tool.dailyCommand)
        return try parseDailyTotals(for: tool, data: data)
    }

    private func runCommand(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            let combined = [output, errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
            throw FetchError.commandFailed(combined)
        }

        return data
    }

    private func parseDailyTotals(for tool: UsageTool, data: Data) throws -> [DailyTotal] {
        if let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        let dailyRows: [[String: Any]]

        if let dict = json as? [String: Any] {
            dailyRows = dict["daily"] as? [[String: Any]] ?? []
        } else if let array = json as? [[String: Any]] {
            dailyRows = array
        } else {
            throw FetchError.invalidOutput
        }

        let costKey = tool == .claude ? "totalCost" : "costUSD"

        return dailyRows.compactMap { row in
            guard let rawDate = row["date"] as? String else {
                return nil
            }
            let dateKey = tool == .codex ? (DateHelper.normalizedDateKey(from: rawDate) ?? rawDate) : rawDate
            guard let cost = parseNumber(row[costKey]) else {
                return nil
            }
            return DailyTotal(dateKey: dateKey, cost: cost)
        }
    }

    private func parseNumber(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }
}

extension UsageFetcher.FetchError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            return output.isEmpty ? "Usage command failed." : output
        case .invalidOutput:
            return "Usage command returned invalid JSON."
        }
    }
}
