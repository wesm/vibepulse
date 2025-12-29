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
