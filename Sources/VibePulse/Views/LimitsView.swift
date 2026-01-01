import SwiftUI

struct LimitsView: View {
  let claudeLimits: [UsageLimit]
  let codexLimits: [UsageLimit]
  let claudeError: String?
  let codexError: String?
  let showClaude: Bool
  let showCodex: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if showClaude {
        LimitsSectionView(tool: .claude, limits: claudeLimits, errorMessage: claudeError)
      }

      if showCodex {
        LimitsSectionView(tool: .codex, limits: codexLimits, errorMessage: codexError)
      }

      if !showClaude && !showCodex {
        Text("Enable Claude Code or Codex in Settings to view limits.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }
}

private struct LimitsSectionView: View {
  let tool: UsageTool
  let limits: [UsageLimit]
  let errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(tool.displayName)
        .font(.caption)
        .foregroundColor(.secondary)

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundColor(.red)
      } else if limits.isEmpty {
        Text("No limits data yet.")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        ForEach(limits) { limit in
          LimitRowView(limit: limit)
        }
      }
    }
  }
}

private struct LimitRowView: View {
  let limit: UsageLimit

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(limit.title)
        Spacer()
        Text(percentText)
          .monospacedDigit()
      }
      .font(.caption)

      if let percent = limit.percentUsed {
        ProgressView(value: min(max(percent, 0), 1))
          .progressViewStyle(.linear)
      }

      Text(resetText)
        .font(.caption2)
        .foregroundColor(.secondary)
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private var percentText: String {
    guard let percent = limit.percentUsed else { return "--" }
    return Formatters.percentString(percent)
  }

  private var resetText: String {
    if let resetAt = limit.resetAt {
      if limit.isWeekly {
        return "Resets \(resetAt.formatted(.dateTime.weekday().month().day().hour().minute()))"
      }
      return "Resets \(resetAt.formatted(.dateTime.hour().minute()))"
    }
    if let resetText = limit.resetText {
      return "Resets \(resetText)"
    }
    return "Reset time unavailable"
  }
}
