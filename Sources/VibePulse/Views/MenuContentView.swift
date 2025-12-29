import AppKit
import SwiftUI

struct MenuContentView: View {
    private static let welcomeKey = "hasSeenWelcome"
    @EnvironmentObject private var model: AppModel
    @State private var chartMode: ChartMode = .today
    @State private var showWelcome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            totalSection
            Picker("View", selection: $chartMode) {
                ForEach(ChartMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(chartMode == .today ? "Cumulative" : "By Day")
                .font(.caption)
                .foregroundColor(.secondary)

            UsageChartView(mode: chartMode, cumulativeSeries: model.cumulativeSeries, dailySeries: model.dailySeries)

            totalsBreakdown

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            controls
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            disableWindowResizing()
            checkWelcome()
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView {
                markWelcomeSeen()
                showWelcome = false
            }
            .environmentObject(model)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3)
                .foregroundColor(.accentColor)
            Text("VibePulse")
                .font(.headline)
            Spacer()
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        ZStack(alignment: .trailing) {
            if let lastUpdated = model.lastUpdated {
                Text(lastUpdated, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .opacity(model.isRefreshing ? 0 : 1)
                    .monospacedDigit()
            } else {
                Text(" ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .opacity(0)
            }

            if model.isRefreshing {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 70, height: 16, alignment: .trailing)
        .animation(.none, value: model.isRefreshing)
    }


    private var totalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(combinedTotalText)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(combinedTotalSubtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var totalsBreakdown: some View {
        HStack(spacing: 12) {
            ForEach(toolBreakdown) { total in
                HStack(spacing: 6) {
                    Circle()
                        .fill(total.tool.color)
                        .frame(width: 8, height: 8)
                    Text("\(total.tool.shortName) \(Formatters.currencyString(total.totalCost))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button("Refresh") {
                model.refreshNow()
            }
            .disabled(model.isRefreshing)

            Button("Settings") {
                model.openSettings()
            }

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private func checkWelcome() {
        if !UserDefaults.standard.bool(forKey: Self.welcomeKey) {
            showWelcome = true
        }
    }

    private func markWelcomeSeen() {
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)
    }

    private func disableWindowResizing() {
        if let window = NSApp.keyWindow {
            window.styleMask.remove(.resizable)
        }
    }

    private var combinedTotalText: String {
        switch chartMode {
        case .today:
            return model.menuTotalText
        case .thirtyDays:
            let total = model.dailySeries.reduce(0) { $0 + $1.cost }
            return Formatters.currencyString(total)
        }
    }

    private var combinedTotalSubtitle: String {
        switch chartMode {
        case .today:
            return "Combined today via ccusage"
        case .thirtyDays:
            return "Combined (last 30 days) via ccusage"
        }
    }

    private var toolBreakdown: [ToolTotal] {
        switch chartMode {
        case .today:
            return model.toolTotals
        case .thirtyDays:
            var totalsByTool: [UsageTool: Double] = [:]
            for point in model.dailySeries {
                totalsByTool[point.tool, default: 0] += point.cost
            }
            return UsageTool.allCases.compactMap { tool in
                guard let total = totalsByTool[tool] else { return nil }
                return ToolTotal(tool: tool, totalCost: total)
            }
        }
    }
}
