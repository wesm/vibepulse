import Foundation

enum ChartMode: String, CaseIterable, Identifiable {
  case today
  case thirtyDays

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today:
      return "Today"
    case .thirtyDays:
      return "30 Days"
    }
  }
}

enum MaintenanceMode: String, CaseIterable, Identifiable {
  case automatic
  case manual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic:
      return "Automatic"
    case .manual:
      return "Manual"
    }
  }

  var detail: String {
    switch self {
    case .automatic:
      return "Runs when the app starts (at most once per day)."
    case .manual:
      return "Only runs when you click the button."
    }
  }
}

enum RefreshInterval: String, CaseIterable, Identifiable {
  case fiveMinutes = "5m"
  case fifteenMinutes = "15m"
  case oneHour = "1h"
  case fourHours = "4h"
  case oneDay = "1d"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fiveMinutes:
      return "Every 5 minutes"
    case .fifteenMinutes:
      return "Every 15 minutes"
    case .oneHour:
      return "Every hour"
    case .fourHours:
      return "Every 4 hours"
    case .oneDay:
      return "Every day"
    }
  }

  var seconds: Int {
    switch self {
    case .fiveMinutes:
      return 5 * 60
    case .fifteenMinutes:
      return 15 * 60
    case .oneHour:
      return 60 * 60
    case .fourHours:
      return 4 * 60 * 60
    case .oneDay:
      return 24 * 60 * 60
    }
  }
}

struct DailyTotal {
  let dateKey: String
  let cost: Double
}

struct UsageSample {
  let tool: UsageTool
  let recordedAt: Date
  let totalCost: Double
  let deltaCost: Double
}

struct DailyRollup {
  let dateKey: String
  let tool: UsageTool
  let totalCost: Double
}

struct UsageSeriesPoint: Identifiable {
  let id = UUID()
  let tool: UsageTool
  let date: Date
  let cost: Double
}

struct ToolTotal: Identifiable {
  let id = UUID()
  let tool: UsageTool
  let totalCost: Double
}
