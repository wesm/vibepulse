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

  func fetchLimits(for tool: UsageTool) throws -> [UsageLimit] {
    switch tool {
    case .claude:
      let data = try runCommand(tool.limitsCommand)
      return try parseLimits(for: tool, data: data)
    case .codex:
      return try fetchCodexLimitsFromLogs()
    }
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

    if let output = String(data: data, encoding: .utf8),
      output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !errorData.isEmpty
    {
      return errorData
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
    let existing =
      ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    var combined: [String] = []
    for path in defaultPaths + existing {
      if !combined.contains(path) {
        combined.append(path)
      }
    }
    return combined
  }

  private func parseDailyTotals(for tool: UsageTool, data: Data) throws -> [DailyTotal] {
    if let text = String(data: data, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
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
      let dateKey =
        tool == .codex ? (DateHelper.normalizedDateKey(from: rawDate) ?? rawDate) : rawDate
      guard let cost = parseNumber(row[costKey]) else {
        return nil
      }
      return DailyTotal(dateKey: dateKey, cost: cost)
    }
  }

  private struct LimitDescriptor {
    let title: String
    let isWeekly: Bool
    let sortOrder: Int
  }

  private func parseLimits(for tool: UsageTool, data: Data) throws -> [UsageLimit] {
    guard let rawText = String(data: data, encoding: .utf8) else {
      throw FetchError.invalidOutput
    }
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw FetchError.invalidOutput }

    if trimmed.first == "{" || trimmed.first == "[" {
      if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
        let jsonLimits = parseLimitsFromJSON(tool: tool, json: json)
        if !jsonLimits.isEmpty {
          return jsonLimits
        }
      }
    }

    let textLimits = parseLimitsFromText(tool: tool, text: trimmed)
    if !textLimits.isEmpty {
      return textLimits
    }

    throw FetchError.invalidOutput
  }

  private func fetchCodexLimitsFromLogs() throws -> [UsageLimit] {
    guard let logURL = latestCodexSessionLogURL() else {
      throw FetchError.invalidOutput
    }

    let rawText = try String(contentsOf: logURL, encoding: .utf8)
    let lines = rawText.split(whereSeparator: \.isNewline)
    for line in lines.reversed() {
      guard let data = line.data(using: .utf8) else { continue }
      guard
        let json = try? JSONSerialization.jsonObject(with: data, options: []),
        let dict = json as? [String: Any],
        let payload = dict["payload"] as? [String: Any],
        let rateLimits = payload["rate_limits"] as? [String: Any]
      else {
        continue
      }

      var limits: [UsageLimit] = []
      if let primary = rateLimits["primary"] as? [String: Any],
        let primaryLimit = codexLimit(from: primary, title: "5h Limit", isWeekly: false, sortOrder: 0)
      {
        limits.append(primaryLimit)
      }
      if let secondary = rateLimits["secondary"] as? [String: Any],
        let secondaryLimit = codexLimit(
          from: secondary, title: "Weekly Limit", isWeekly: true, sortOrder: 1)
      {
        limits.append(secondaryLimit)
      }

      if !limits.isEmpty {
        return limits
      }
    }

    throw FetchError.invalidOutput
  }

  private func latestCodexSessionLogURL() -> URL? {
    let baseURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex")
      .appendingPathComponent("sessions")
    guard
      let enumerator = FileManager.default.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }

    var latestURL: URL?
    var latestDate: Date?
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "jsonl" else { continue }
      guard fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }
      guard
        let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
        let modified = resourceValues.contentModificationDate
      else {
        continue
      }
      if latestDate == nil || modified > latestDate! {
        latestDate = modified
        latestURL = fileURL
      }
    }

    return latestURL
  }

  private func codexLimit(
    from dict: [String: Any],
    title: String,
    isWeekly: Bool,
    sortOrder: Int
  ) -> UsageLimit? {
    guard let usedPercent = parseNumber(dict["used_percent"]) else {
      return nil
    }
    let percentUsed = usedPercent > 1 ? usedPercent / 100.0 : usedPercent
    let resetAt = parseNumber(dict["resets_at"]).map { Date(timeIntervalSince1970: $0) }
    return UsageLimit(
      tool: .codex,
      title: title,
      percentUsed: percentUsed,
      resetAt: resetAt,
      resetText: nil,
      isWeekly: isWeekly,
      sortOrder: sortOrder
    )
  }

  private func parseLimitsFromJSON(tool: UsageTool, json: Any) -> [UsageLimit] {
    if let dict = json as? [String: Any] {
      if let result = dict["result"] as? String {
        let limits = parseLimitsFromText(tool: tool, text: result)
        if !limits.isEmpty {
          return limits
        }
      }

      if let limitsArray = dict["limits"] as? [[String: Any]] {
        return parseLimitsFromArray(tool: tool, array: limitsArray)
      }

      if let usageDict = dict["usage"] as? [String: Any] {
        return parseLimitsFromUsageDictionary(tool: tool, dict: usageDict)
      }
    } else if let array = json as? [[String: Any]] {
      return parseLimitsFromArray(tool: tool, array: array)
    }

    return []
  }

  private func parseLimitsFromArray(tool: UsageTool, array: [[String: Any]]) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    for entry in array {
      guard let title = entry["title"] as? String ?? entry["name"] as? String else {
        continue
      }
      let descriptor = descriptor(for: tool, line: title)
      let isWeekly = descriptor?.isWeekly ?? title.lowercased().contains("week")
      let sortOrder = descriptor?.sortOrder ?? 10
      let percentUsed = parsePercent(from: entry)
      let resetValue = entry["resetAt"] ?? entry["reset_at"] ?? entry["reset"]
      let (resetAt, resetText) = parseReset(from: resetValue)
      limits.append(
        UsageLimit(
          tool: tool,
          title: descriptor?.title ?? title,
          percentUsed: percentUsed,
          resetAt: resetAt,
          resetText: resetText,
          isWeekly: isWeekly,
          sortOrder: sortOrder
        ))
    }
    return limits.sorted { $0.sortOrder < $1.sortOrder }
  }

  private func parseLimitsFromUsageDictionary(tool: UsageTool, dict: [String: Any]) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    for (key, value) in dict {
      guard let entry = value as? [String: Any] else { continue }
      let descriptor = descriptor(for: tool, line: key)
      let title = descriptor?.title ?? key.capitalized
      let isWeekly = descriptor?.isWeekly ?? key.lowercased().contains("week")
      let sortOrder = descriptor?.sortOrder ?? 10
      let percentUsed = parsePercent(from: entry)
      let resetValue = entry["resetAt"] ?? entry["reset_at"] ?? entry["reset"]
      let (resetAt, resetText) = parseReset(from: resetValue)
      limits.append(
        UsageLimit(
          tool: tool,
          title: title,
          percentUsed: percentUsed,
          resetAt: resetAt,
          resetText: resetText,
          isWeekly: isWeekly,
          sortOrder: sortOrder
        ))
    }
    return limits.sorted { $0.sortOrder < $1.sortOrder }
  }

  private func parseLimitsFromText(tool: UsageTool, text: String) -> [UsageLimit] {
    let cleaned = stripANSI(text)
    let lines =
      cleaned
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var limitsByTitle: [String: UsageLimit] = [:]
    for line in lines {
      guard let descriptor = descriptor(for: tool, line: line) else {
        continue
      }
      let percentUsed = parsePercent(in: line)
      let resetText = parseResetText(in: line)
      let resetAt = resetText.flatMap { parseResetDate(from: $0) }
      let limit = UsageLimit(
        tool: tool,
        title: descriptor.title,
        percentUsed: percentUsed,
        resetAt: resetAt,
        resetText: resetText,
        isWeekly: descriptor.isWeekly,
        sortOrder: descriptor.sortOrder
      )
      limitsByTitle[descriptor.title] = limit
    }

    return limitsByTitle.values.sorted { $0.sortOrder < $1.sortOrder }
  }

  private func descriptor(for tool: UsageTool, line: String) -> LimitDescriptor? {
    let lower = line.lowercased()
    switch tool {
    case .claude:
      if lower.contains("session") {
        return LimitDescriptor(title: "Session", isWeekly: false, sortOrder: 0)
      }
      if lower.contains("sonnet") {
        return LimitDescriptor(title: "Weekly (sonnet only)", isWeekly: true, sortOrder: 2)
      }
      if lower.contains("weekly") {
        if lower.contains("all") {
          return LimitDescriptor(title: "Weekly (all models)", isWeekly: true, sortOrder: 1)
        }
        return LimitDescriptor(title: "Weekly (all models)", isWeekly: true, sortOrder: 1)
      }
    case .codex:
      if lower.contains("5h") || lower.contains("5-hour") || lower.contains("5 hour")
        || lower.contains("5 hours")
      {
        return LimitDescriptor(title: "5h Limit", isWeekly: false, sortOrder: 0)
      }
      if lower.contains("weekly") {
        return LimitDescriptor(title: "Weekly Limit", isWeekly: true, sortOrder: 1)
      }
    }
    return nil
  }

  private func parsePercent(in line: String) -> Double? {
    if let percentMatch = firstMatch(pattern: #"(\d+(?:\.\d+)?)\s*%"#, in: line),
      let percentString = percentMatch.first,
      let value = Double(percentString)
    {
      return value / 100.0
    }

    if let ratio = firstMatch(pattern: #"(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)"#, in: line),
      ratio.count == 2,
      let used = Double(ratio[0]),
      let limit = Double(ratio[1]),
      limit > 0
    {
      return used / limit
    }

    if let ratio = firstMatch(pattern: #"(\d+(?:\.\d+)?)\s+of\s+(\d+(?:\.\d+)?)"#, in: line),
      ratio.count == 2,
      let used = Double(ratio[0]),
      let limit = Double(ratio[1]),
      limit > 0
    {
      return used / limit
    }

    return nil
  }

  private func parsePercent(from entry: [String: Any]) -> Double? {
    let percentKeys = ["percent", "percentUsed", "percentage", "pct"]
    for key in percentKeys {
      if let value = parseNumber(entry[key]) {
        return value > 1 ? value / 100.0 : value
      }
    }

    let usedKeys = ["used", "usage", "current", "spent"]
    let limitKeys = ["limit", "cap", "max", "total"]
    for usedKey in usedKeys {
      for limitKey in limitKeys {
        if let used = parseNumber(entry[usedKey]),
          let limit = parseNumber(entry[limitKey]),
          limit > 0
        {
          return used / limit
        }
      }
    }

    return nil
  }

  private func parseReset(from value: Any?) -> (Date?, String?) {
    if let number = value as? NSNumber {
      return (Date(timeIntervalSince1970: number.doubleValue), nil)
    }
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if let date = parseResetDate(from: trimmed) {
        return (date, nil)
      }
      return (nil, trimmed.isEmpty ? nil : trimmed)
    }
    return (nil, nil)
  }

  private func parseResetText(in line: String) -> String? {
    guard let match = firstMatch(pattern: #"(?i)reset[s]?\s*(.*)$"#, in: line),
      let value = match.first
    else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: ":.-"))
    return trimmed.isEmpty ? nil : trimmed
  }

  private func parseResetDate(from value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "^at\\s+", with: "", options: .regularExpression)
      .replacingOccurrences(of: "^on\\s+", with: "", options: .regularExpression)

    if let date = ISO8601DateFormatter().date(from: trimmed) {
      return date
    }

    let formats = [
      "yyyy-MM-dd HH:mm",
      "yyyy-MM-dd h:mm a",
      "MMM d, yyyy HH:mm",
      "MMM d, yyyy h:mm a",
      "MMM d, yyyy 'at' h:mm a",
      "MMM d, yyyy 'at' HH:mm",
      "EEE MMM d, yyyy HH:mm",
      "EEE MMM d, yyyy h:mm a",
    ]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    for format in formats {
      formatter.dateFormat = format
      if let date = formatter.date(from: trimmed) {
        return date
      }
    }
    return nil
  }

  private func firstMatch(pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else {
      return nil
    }
    var results: [String] = []
    for index in 1..<match.numberOfRanges {
      let range = match.range(at: index)
      if let swiftRange = Range(range, in: text) {
        results.append(String(text[swiftRange]))
      }
    }
    return results.isEmpty ? nil : results
  }

  private func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\u001B\[[0-9;]*m"#,
      with: "",
      options: .regularExpression
    )
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
