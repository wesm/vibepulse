import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var menuTotalText: String = Formatters.currencyString(0)
    @Published var hourlySeries: [UsageSeriesPoint] = []
    @Published var dailySeries: [UsageSeriesPoint] = []
    @Published var toolTotals: [ToolTotal] = []
    @Published var lastUpdated: Date?
    @Published var statusMessage: String?
    @Published var isRefreshing = false
    @Published var isMaintaining = false
    @Published var maintenanceMode: MaintenanceMode {
        didSet {
            defaults.set(maintenanceMode.rawValue, forKey: DefaultsKey.maintenanceMode)
            if maintenanceMode == .automatic {
                runMaintenanceIfNeeded()
            }
        }
    }
    @Published var lastMaintenanceAt: Date?
    @Published var maintenanceMessage: String?

    @Published var includeClaude: Bool {
        didSet {
            defaults.set(includeClaude, forKey: DefaultsKey.includeClaude)
            reloadFromStore()
        }
    }

    @Published var includeCodex: Bool {
        didSet {
            defaults.set(includeCodex, forKey: DefaultsKey.includeCodex)
            reloadFromStore()
        }
    }

    @Published var refreshMinutes: Double {
        didSet {
            defaults.set(refreshMinutes, forKey: DefaultsKey.refreshMinutes)
            scheduleTimer()
        }
    }

    private let defaults = UserDefaults.standard
    private let fetcher = UsageFetcher()
    private var timer: DispatchSourceTimer?
    private let store: UsageStore

    init() {
        includeClaude = defaults.object(forKey: DefaultsKey.includeClaude) as? Bool ?? true
        includeCodex = defaults.object(forKey: DefaultsKey.includeCodex) as? Bool ?? true
        let storedInterval = defaults.object(forKey: DefaultsKey.refreshMinutes) as? Double
        refreshMinutes = storedInterval ?? 10
        let storedMode = defaults.string(forKey: DefaultsKey.maintenanceMode)
        maintenanceMode = MaintenanceMode(rawValue: storedMode ?? "") ?? .automatic
        if let storedMaintenance = defaults.object(forKey: DefaultsKey.lastMaintenanceAt) as? Double {
            lastMaintenanceAt = Date(timeIntervalSince1970: storedMaintenance)
        }

        do {
            store = try UsageStore.defaultStore()
        } catch {
            store = try! UsageStore(path: ":memory:")
            statusMessage = "Database unavailable. Running without persistence."
        }

        reloadFromStore()
        scheduleTimer()
        refreshNow()
        runMaintenanceIfNeeded()
    }

    func refreshNow() {
        guard !isRefreshing else { return }

        let tools = activeTools
        guard !tools.isEmpty else {
            statusMessage = "Enable Claude Code or Codex in Settings."
            return
        }

        isRefreshing = true
        statusMessage = nil

        let todayKey = DateHelper.dateKey(for: Date())

        DispatchQueue.global(qos: .background).async { [fetcher, store] in
            var errors: [String] = []

            for tool in tools {
                do {
                    let totals = try fetcher.fetchDailyTotals(for: tool)
                    try store.upsertDailyTotals(tool: tool, totals: totals)
                    if let todayTotal = totals.first(where: { $0.dateKey == todayKey }) {
                        try store.insertSample(tool: tool, totalCost: todayTotal.cost, recordedAt: Date())
                    }
                } catch {
                    errors.append("\(tool.displayName): \(error.localizedDescription)")
                }
            }

            let refreshTime = Date()

            DispatchQueue.main.async {
                if !errors.isEmpty {
                    self.statusMessage = errors.joined(separator: " | ")
                } else {
                    self.lastUpdated = refreshTime
                }
                self.reloadFromStore()
                self.isRefreshing = false
            }
        }
    }

    private var activeTools: [UsageTool] {
        UsageTool.allCases.filter { tool in
            switch tool {
            case .claude:
                return includeClaude
            case .codex:
                return includeCodex
            }
        }
    }

    private func reloadFromStore() {
        let tools = activeTools
        let startOfDay = DateHelper.startOfToday()
        let now = Date()
        var hourlyPoints: [UsageSeriesPoint] = []

        for tool in tools {
            let samples = store.fetchSamples(tool: tool, from: startOfDay, to: now).sorted { $0.recordedAt < $1.recordedAt }
            hourlyPoints.append(contentsOf: HourlyUsageInferer.inferPoints(tool: tool, samples: samples, startOfDay: startOfDay, end: now))
        }

        hourlySeries = hourlyPoints.sorted { $0.date < $1.date }

        let sinceKey = DateHelper.dateKeyDaysAgo(29)
        let rollups = store.fetchDailyRollups(since: sinceKey)
        dailySeries = rollups.compactMap { rollup in
            guard tools.contains(rollup.tool), let date = DateHelper.date(fromKey: rollup.dateKey) else {
                return nil
            }
            return UsageSeriesPoint(tool: rollup.tool, date: date, cost: rollup.totalCost)
        }

        let todayKey = DateHelper.dateKey(for: Date())
        var totals: [ToolTotal] = []
        for tool in tools {
            let dailyTotal = store.dailyTotal(for: todayKey, tool: tool)
            let sampleTotal = store.latestSample(for: todayKey, tool: tool)?.totalCost
            let totalCost = dailyTotal ?? sampleTotal ?? 0
            totals.append(ToolTotal(tool: tool, totalCost: totalCost))
        }
        toolTotals = totals
        let combined = totals.reduce(0) { $0 + $1.totalCost }
        menuTotalText = Formatters.currencyString(combined)
    }

    func runMaintenance(force: Bool = false) {
        guard !isMaintaining else { return }
        guard force || maintenanceMode == .automatic else { return }

        if !force, let lastMaintenanceAt, Date().timeIntervalSince(lastMaintenanceAt) < 60 * 60 * 24 {
            return
        }

        isMaintaining = true
        maintenanceMessage = nil

        DispatchQueue.global(qos: .background).async { [store] in
            do {
                let deltaUpdated = try store.backfillSampleDeltas()
                let dateUpdated = try store.normalizeDailyRollupDates(for: .codex)
                let message = "Maintenance complete. Updated \(deltaUpdated) snapshots, normalized \(dateUpdated) daily totals."
                let now = Date()
                DispatchQueue.main.async {
                    self.maintenanceMessage = message
                    self.lastMaintenanceAt = now
                    self.defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.lastMaintenanceAt)
                    self.reloadFromStore()
                    self.isMaintaining = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.maintenanceMessage = "Maintenance failed: \(error.localizedDescription)"
                    self.isMaintaining = false
                }
            }
        }
    }

    private func runMaintenanceIfNeeded() {
        runMaintenance(force: false)
    }

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        let intervalSeconds = max(60, Int(refreshMinutes * 60))
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(intervalSeconds))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private enum DefaultsKey {
        static let includeClaude = "includeClaude"
        static let includeCodex = "includeCodex"
        static let refreshMinutes = "refreshMinutes"
        static let maintenanceMode = "maintenanceMode"
        static let lastMaintenanceAt = "lastMaintenanceAt"
    }
}
