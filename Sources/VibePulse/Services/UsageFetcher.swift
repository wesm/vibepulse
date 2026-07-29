import Foundation

final class UsageFetcher: @unchecked Sendable {
  enum FetchError: Error {
    case commandFailed(String)
    case invalidOutput
    case agentsviewNotFound(String?)
  }

  private let commandRunner: (([String]) throws -> Data)?

  init(commandRunner: (([String]) throws -> Data)? = nil) {
    self.commandRunner = commandRunner
  }

  func fetchDailyTotals(for tool: UsageTool) throws -> [DailyTotal] {
    // Retry transient failures so a refresh that lands while
    // agentsview is mid-replace (self-update or reinstall) doesn't
    // surface an error that sticks until the next scheduled refresh.
    let maxAttempts = 3
    let retryDelay: TimeInterval = 0.3

    for attempt in 1...maxAttempts {
      do {
        let data: Data
        do {
          data = try executeCommand(tool.dailyCommand)
        } catch FetchError.commandFailed(let output)
          where Self.isUnsupportedBreakdownError(output)
        {
          data = try executeCommand(tool.dailyCommand.filter { $0 != "--breakdown" })
        }
        return try Self.parseDailyTotals(data: data)
      } catch FetchError.agentsviewNotFound(let path) {
        throw FetchError.agentsviewNotFound(path)
      } catch {
        if attempt == maxAttempts {
          throw error
        }
        Thread.sleep(forTimeInterval: retryDelay)
      }
    }

    // Unreachable: the loop returns on success or throws on the
    // final attempt, but the compiler can't prove it.
    throw FetchError.commandFailed("retry loop exhausted")
  }

  private func executeCommand(_ arguments: [String]) throws -> Data {
    if let commandRunner {
      return try commandRunner(arguments)
    }
    return try runCommand(arguments)
  }

  private static func isUnsupportedBreakdownError(_ output: String) -> Bool {
    let message = output.lowercased()
    guard message.contains("--breakdown") else { return false }
    return [
      "unknown flag",
      "unknown option",
      "unrecognized argument",
      "unrecognized option",
      "unexpected argument",
      "flag provided but not defined",
    ].contains { message.contains($0) }
  }

  private func runCommand(_ arguments: [String]) throws -> Data {
    let (executableURL, resolvedArguments) =
      try resolveCommand(arguments: arguments)
    let process = Process()
    process.executableURL = executableURL
    process.arguments = resolvedArguments
    process.environment = buildEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()

    // Drain both pipes concurrently. Reading stdout to EOF before stderr
    // deadlocks once the child writes more than the pipe buffer (~64 KB on
    // macOS) to stderr — agentsview's full-resync progress output after a
    // dataVersion bump exceeds that and would otherwise hang the refresh
    // until the app is relaunched.
    var data = Data()
    var errorData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      data = outputPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.wait()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let output = String(data: data, encoding: .utf8) ?? ""
      let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
      let combined =
        [output, errorOutput].filter { !$0.isEmpty }
        .joined(separator: "\n")
      throw FetchError.commandFailed(combined)
    }

    return data
  }

  private func resolveCommand(
    arguments: [String]
  ) throws -> (URL, [String]) {
    guard let first = arguments.first, first == "agentsview" else {
      return (URL(fileURLWithPath: "/usr/bin/env"), arguments)
    }

    let override = UserDefaults.standard.string(
      forKey: "agentsviewPath"
    )
    if let override, !override.isEmpty {
      if FileManager.default.isExecutableFile(atPath: override) {
        return (
          URL(fileURLWithPath: override),
          Array(arguments.dropFirst())
        )
      }
      throw FetchError.agentsviewNotFound(override)
    }

    if let resolved = resolveAgentsviewExecutable() {
      return (
        URL(fileURLWithPath: resolved),
        Array(arguments.dropFirst())
      )
    }

    throw FetchError.agentsviewNotFound(nil)
  }

  private func resolveAgentsviewExecutable() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/.local/bin/agentsview",
      "/usr/local/bin/agentsview",
      "/opt/homebrew/bin/agentsview",
    ]
    for path in candidates {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    let paths = buildSearchPaths()
    for directory in paths {
      let path =
        (directory as NSString).appendingPathComponent("agentsview")
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
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let defaultPaths = [
      "\(home)/.local/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    let existing =
      ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":").map(String.init) ?? []
    var combined: [String] = []
    for path in defaultPaths + existing {
      if !combined.contains(path) {
        combined.append(path)
      }
    }
    return combined
  }

  static func parseDailyTotals(data: Data) throws -> [DailyTotal] {
    if let text = String(data: data, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return []
    }
    let json = try JSONSerialization.jsonObject(
      with: data, options: []
    )
    let dailyRows: [[String: Any]]

    if let dict = json as? [String: Any] {
      dailyRows = dict["daily"] as? [[String: Any]] ?? []
    } else if let array = json as? [[String: Any]] {
      dailyRows = array
    } else {
      throw FetchError.invalidOutput
    }

    return dailyRows.compactMap { row in
      guard let dateKey = row["date"] as? String else {
        return nil
      }
      guard let cost = parseNumber(row["totalCost"]) else {
        return nil
      }
      let modelBreakdowns = parseModelBreakdowns(row["modelBreakdowns"])
      let machineBreakdowns = parseMachineBreakdowns(row["machineBreakdowns"])
      return DailyTotal(
        dateKey: dateKey,
        cost: cost,
        modelBreakdowns: modelBreakdowns,
        machineBreakdowns: machineBreakdowns)
    }
  }

  private static func parseModelBreakdowns(_ value: Any?) -> [DailyModelBreakdown]? {
    guard let value else { return nil }
    guard let rows = value as? [[String: Any]] else { return nil }
    var modelBreakdowns: [DailyModelBreakdown] = []
    for row in rows {
      guard let modelName = row["modelName"] as? String, !modelName.isEmpty else {
        return nil
      }
      guard let cost = parseNumber(row["cost"]) else {
        return nil
      }
      modelBreakdowns.append(DailyModelBreakdown(modelName: modelName, cost: cost))
    }
    return modelBreakdowns
  }

  private static func parseMachineBreakdowns(_ value: Any?) -> [DailyMachineBreakdown]? {
    guard let value else { return nil }
    guard let rows = value as? [[String: Any]] else { return nil }
    var breakdowns: [DailyMachineBreakdown] = []
    for row in rows {
      guard let machineName = row["machineName"] as? String, !machineName.isEmpty else {
        return nil
      }
      guard let cost = parseNumber(row["cost"]) else {
        return nil
      }
      breakdowns.append(DailyMachineBreakdown(machineName: machineName, cost: cost))
    }
    return breakdowns
  }

  private static func parseNumber(_ value: Any?) -> Double? {
    if let money = value as? [String: Any],
      let microdollars = parseNumber(money["microdollars"])
    {
      return microdollars / 1_000_000
    }
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
    case .agentsviewNotFound(let override):
      if let override {
        return
          "agentsview not found at \(override). "
          + "Update the path in Settings or install agentsview."
      }
      return
        "agentsview not found. "
        + "Install it (https://agentsview.io) "
        + "or set the path in Settings."
    }
  }
}
