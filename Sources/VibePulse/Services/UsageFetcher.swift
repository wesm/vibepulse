import Foundation

protocol UsageFetching: Sendable {
  func discoverAgents(using context: UsageDateContext) throws -> [UsageAgent]
  func fetchDailyTotals(
    for tool: UsageAgent,
    using context: UsageDateContext
  ) throws -> [DailyTotal]
}

final class UsageFetcher: UsageFetching, @unchecked Sendable {
  enum FetchError: Error {
    case commandFailed(String)
    case invalidOutput
    case agentsviewNotFound(String?)
    case invalidServerURL(String)
    case unsupportedTimezone
  }

  private let commandRunner: (([String]) throws -> Data)?

  init(commandRunner: (([String]) throws -> Data)? = nil) {
    self.commandRunner = commandRunner
  }

  func discoverAgents(using context: UsageDateContext) throws -> [UsageAgent] {
    try withRetry {
      let data = try fetchUsageData(
        command: UsageAgent.discoveryCommand(in: context.timeZone),
        agent: nil,
        context: context)
      return try Self.parseDiscoveredAgents(data: data)
    }
  }

  func fetchDailyTotals(
    for tool: UsageAgent,
    using context: UsageDateContext
  ) throws -> [DailyTotal] {
    try withRetry {
      let data: Data
      do {
        data = try fetchUsageData(
          command: tool.dailyCommand(in: context.timeZone),
          agent: tool.rawValue,
          context: context)
      } catch FetchError.commandFailed(let output)
        where Self.isUnsupportedBreakdownError(output)
      {
        data = try executeAgentsviewCommand(
          tool.dailyCommand(in: context.timeZone).filter { $0 != "--breakdown" })
      }
      let totals = try Self.parseDailyTotals(data: data)
      guard
        totals.allSatisfy({
          DateHelper.normalizedDateKey(from: $0.dateKey, in: context.timeZone) != nil
        })
      else {
        throw FetchError.invalidOutput
      }
      return totals
    }
  }

  private func fetchUsageData(
    command: [String],
    agent: String?,
    context: UsageDateContext
  ) throws -> Data {
    let configuredURL =
      UserDefaults.standard.string(forKey: "agentsviewServerURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !configuredURL.isEmpty else {
      return try executeAgentsviewCommand(command)
    }

    let url = try Self.makeServerURL(
      configuredURL: configuredURL,
      agent: agent,
      now: context.now,
      timeZone: context.timeZone)
    return try Data(contentsOf: url)
  }

  static func makeServerURL(
    configuredURL: String,
    agent: String?,
    now: Date,
    timeZone: TimeZone
  ) throws -> URL {
    let baseURL = configuredURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard
      var components = URLComponents(
        string: baseURL + "/api/v1/usage/summary")
    else {
      throw FetchError.invalidServerURL(configuredURL)
    }

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let from = formatter.string(
      from: now.addingTimeInterval(-30 * 24 * 60 * 60))

    components.queryItems = [
      URLQueryItem(name: "from", value: from),
      URLQueryItem(name: "no_default_range", value: "true"),
      URLQueryItem(name: "timezone", value: timeZone.identifier),
      URLQueryItem(name: "breakdowns", value: "true"),
    ]
    if let agent {
      components.queryItems?.append(URLQueryItem(name: "agent", value: agent))
    }
    guard let url = components.url else {
      throw FetchError.invalidServerURL(configuredURL)
    }
    return url
  }

  private func withRetry<T>(_ operation: () throws -> T) throws -> T {
    let maxAttempts = 3
    let retryDelay: TimeInterval = 0.3

    for attempt in 1...maxAttempts {
      do {
        return try operation()
      } catch FetchError.agentsviewNotFound(let path) {
        throw FetchError.agentsviewNotFound(path)
      } catch FetchError.unsupportedTimezone {
        throw FetchError.unsupportedTimezone
      } catch {
        if attempt == maxAttempts {
          throw error
        }
        Thread.sleep(forTimeInterval: retryDelay)
      }
    }

    throw FetchError.commandFailed("retry loop exhausted")
  }

  private func executeCommand(_ arguments: [String]) throws -> Data {
    if let commandRunner {
      return try commandRunner(arguments)
    }
    return try runCommand(arguments)
  }

  private func executeAgentsviewCommand(_ arguments: [String]) throws -> Data {
    do {
      return try executeCommand(arguments)
    } catch FetchError.commandFailed(let output)
      where Self.isUnsupportedTimezoneError(output)
    {
      throw FetchError.unsupportedTimezone
    }
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

  private static func isUnsupportedTimezoneError(_ output: String) -> Bool {
    let message = output.lowercased()
    let rejectionMarkers = [
      "unknown flag",
      "unknown option",
      "unrecognized argument",
      "unrecognized option",
      "unexpected argument",
      "flag provided but not defined",
    ]
    return message.split(whereSeparator: { $0.isNewline }).contains { line in
      let line = String(line)
      return line.contains("--timezone")
        && rejectionMarkers.contains { line.contains($0) }
    }
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

  static func parseDiscoveredAgents(data: Data) throws -> [UsageAgent] {
    if let text = String(data: data, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw FetchError.invalidOutput
    }

    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dailyRows = root["daily"] as? [[String: Any]]
    else {
      throw FetchError.invalidOutput
    }

    var costByAgent: [String: Double] = [:]
    for dailyRow in dailyRows {
      guard let breakdowns = dailyRow["agentBreakdowns"] as? [Any] else {
        continue
      }
      for rawBreakdown in breakdowns {
        guard
          let breakdown = rawBreakdown as? [String: Any],
          let rawAgent = breakdown["agent"] as? String,
          !rawAgent.isEmpty,
          let cost = parseNumber(breakdown["cost"])
        else {
          continue
        }
        costByAgent[rawAgent, default: 0] += cost
      }
    }

    return
      costByAgent
      .filter { $0.value > 0 }
      .map { UsageAgent($0.key) }
      .sorted()
  }

  static func parseDailyTotals(data: Data) throws -> [DailyTotal] {
    if let text = String(data: data, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw FetchError.invalidOutput
    }
    let json = try JSONSerialization.jsonObject(
      with: data, options: []
    )
    let dailyRows: [Any]

    if let dict = json as? [String: Any] {
      guard let rows = dict["daily"] as? [Any] else {
        throw FetchError.invalidOutput
      }
      dailyRows = rows
    } else if let array = json as? [Any] {
      dailyRows = array
    } else {
      throw FetchError.invalidOutput
    }

    var totals: [DailyTotal] = []
    for rawRow in dailyRows {
      guard
        let row = rawRow as? [String: Any],
        let dateKey = row["date"] as? String,
        !dateKey.isEmpty,
        let cost = parseNumber(row["totalCost"])
      else {
        throw FetchError.invalidOutput
      }
      let modelBreakdowns = try parseModelBreakdowns(row["modelBreakdowns"])
      let machineBreakdowns = try parseMachineBreakdowns(row["machineBreakdowns"])
      totals.append(
        DailyTotal(
          dateKey: dateKey,
          cost: cost,
          modelBreakdowns: modelBreakdowns,
          machineBreakdowns: machineBreakdowns))
    }
    return totals
  }

  private static func parseModelBreakdowns(_ value: Any?) throws -> [DailyModelBreakdown]? {
    guard let value else { return nil }
    guard let rows = value as? [Any] else { throw FetchError.invalidOutput }
    var modelBreakdowns: [DailyModelBreakdown] = []
    for rawRow in rows {
      guard
        let row = rawRow as? [String: Any],
        let modelName = row["modelName"] as? String,
        !modelName.isEmpty,
        let cost = parseNumber(row["cost"])
      else {
        throw FetchError.invalidOutput
      }
      modelBreakdowns.append(DailyModelBreakdown(modelName: modelName, cost: cost))
    }
    return modelBreakdowns
  }

  private static func parseMachineBreakdowns(_ value: Any?) throws -> [DailyMachineBreakdown]? {
    guard let value else { return nil }
    guard let rows = value as? [Any] else { throw FetchError.invalidOutput }
    var breakdowns: [DailyMachineBreakdown] = []
    for rawRow in rows {
      guard
        let row = rawRow as? [String: Any],
        let machineName = row["machineName"] as? String,
        !machineName.isEmpty,
        let cost = parseNumber(row["cost"])
      else {
        throw FetchError.invalidOutput
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
      return doubleValue.isFinite ? doubleValue : nil
    }
    if let number = value as? NSNumber {
      let parsed = number.doubleValue
      return parsed.isFinite ? parsed : nil
    }
    if let string = value as? String,
      let parsed = Double(string),
      parsed.isFinite
    {
      return parsed
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
    case .invalidServerURL(let url):
      return "Invalid agentsview server URL: \(url)"
    case .unsupportedTimezone:
      return
        "A current agentsview release with --timezone support is required. "
        + "Update agentsview and try again."
    }
  }
}
