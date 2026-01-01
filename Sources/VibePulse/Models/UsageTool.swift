import SwiftUI

enum UsageTool: String, CaseIterable, Identifiable {
  case claude
  case codex

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .claude:
      return "Claude Code"
    case .codex:
      return "Codex"
    }
  }

  var shortName: String {
    switch self {
    case .claude:
      return "CC"
    case .codex:
      return "Codex"
    }
  }

  var color: Color {
    switch self {
    case .claude:
      return Color(red: 0.19, green: 0.58, blue: 0.78)
    case .codex:
      return Color(red: 0.86, green: 0.44, blue: 0.27)
    }
  }

  var dailyCommand: [String] {
    switch self {
    case .claude:
      return ["npx", "--yes", "ccusage@latest", "daily", "--json"]
    case .codex:
      return ["npx", "--yes", "@ccusage/codex@latest", "daily", "--json", "--locale", "en-CA"]
    }
  }

  var limitsCommand: [String] {
    switch self {
    case .claude:
      return ["claude", "--print", "/usage", "--output-format", "text"]
    case .codex:
      return ["codex", "exec", "--skip-git-repo-check", "--color", "never", "/status"]
    }
  }
}
