import Foundation

struct UsageAgent: Hashable, Identifiable, Comparable, Sendable {
  let rawValue: String

  init(_ rawValue: String) {
    precondition(!rawValue.isEmpty, "UsageAgent identifiers must not be empty")
    self.rawValue = rawValue
  }

  var id: String { rawValue }

  var displayName: String {
    Self.knownDisplayNames[rawValue] ?? Self.generatedDisplayName(from: rawValue)
  }

  var shortName: String {
    rawValue == "claude" ? "CC" : displayName
  }

  var dailyCommand: [String] {
    [
      "agentsview", "usage", "daily", "--format", "json", "--breakdown", "--agent",
      rawValue, "--since", "30d", "--no-sync",
    ]
  }

  static let discoveryCommand = [
    "agentsview", "usage", "daily", "--format", "json", "--breakdown", "--since", "30d",
  ]

  static let claude = UsageAgent("claude")
  static let codex = UsageAgent("codex")
  static let pi = UsageAgent("pi")
  static let omp = UsageAgent("omp")
  static let gemini = UsageAgent("gemini")
  static let openCode = UsageAgent("opencode")
  static let copilot = UsageAgent("copilot")

  static func < (lhs: UsageAgent, rhs: UsageAgent) -> Bool {
    let lhsName = lhs.displayName.lowercased()
    let rhsName = rhs.displayName.lowercased()
    if lhsName == rhsName {
      return lhs.rawValue < rhs.rawValue
    }
    return lhsName < rhsName
  }

  private static let knownDisplayNames = [
    "claude": "Claude Code",
    "codex": "Codex",
    "pi": "Pi",
    "omp": "OhMyPi",
    "gemini": "Gemini",
    "opencode": "OpenCode",
    "copilot": "GitHub Copilot",
  ]

  private static func generatedDisplayName(from rawValue: String) -> String {
    rawValue
      .replacingOccurrences(of: "_", with: "-")
      .split(separator: "-")
      .map { word in
        word.prefix(1).uppercased() + String(word.dropFirst())
      }
      .joined(separator: " ")
  }
}
