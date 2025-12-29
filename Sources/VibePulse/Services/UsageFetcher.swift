import Foundation

final class UsageFetcher: @unchecked Sendable {
    enum FetchError: Error {
        case commandFailed(String)
        case invalidOutput
        case npxNotFound(String?)
    }

    func fetchDailyTotals(for tool: UsageTool) throws -> [DailyTotal] {
        let data = try runCommand(tool.dailyCommand)
        return try parseDailyTotals(for: tool, data: data)
    }

    private func runCommand(_ arguments: [String]) throws -> Data {
        let (executableURL, resolvedArguments) = try resolveCommand(arguments: arguments)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = resolvedArguments
        process.environment = buildEnvironment()

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

    private func resolveCommand(arguments: [String]) throws -> (URL, [String]) {
        guard let first = arguments.first else {
            return (URL(fileURLWithPath: "/usr/bin/env"), arguments)
        }

        if first == "npx" {
            if let override = UserDefaults.standard.string(forKey: "npxPath"), !override.isEmpty {
                if FileManager.default.isExecutableFile(atPath: override) {
                    return (URL(fileURLWithPath: override), Array(arguments.dropFirst()))
                }
                throw FetchError.npxNotFound(override)
            }

            if let npxPath = resolveNpxExecutable() {
                return (URL(fileURLWithPath: npxPath), Array(arguments.dropFirst()))
            }

            throw FetchError.npxNotFound(nil)
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), arguments)
    }

    private func resolveNpxExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            "/usr/bin/npx",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let paths = buildSearchPaths()
        for directory in paths {
            let path = (directory as NSString).appendingPathComponent("npx")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func buildEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = buildSearchPaths().joined(separator: ":")
        return environment
    }

    private func buildSearchPaths() -> [String] {
        let defaultPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var combined: [String] = []
        for path in defaultPaths + existing {
            if !combined.contains(path) {
                combined.append(path)
            }
        }
        return combined
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
        case .npxNotFound(let override):
            if let override {
                return "npx not found at \(override). Update the path in Settings or install Node.js."
            }
            return "npx not found. Install Node.js or set the npx path in Settings."
        }
    }
}
