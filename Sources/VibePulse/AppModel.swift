import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
  @Published var menuTotalText: String = Formatters.currencyString(0)
  @Published var hourlySeries: [UsageSeriesPoint] = []
  @Published var cumulativeSeries: [UsageSeriesPoint] = []
  @Published var dailySeries: [UsageSeriesPoint] = []
  @Published var toolTotals: [ToolTotal] = []
  @Published var modelCumulativeSeries: [UsageSeriesPoint] = []
  @Published var modelDailySeries: [UsageSeriesPoint] = []
  @Published var modelTotals: [ToolTotal] = []
  @Published var machineCumulativeSeries: [UsageSeriesPoint] = []
  @Published var machineDailySeries: [UsageSeriesPoint] = []
  @Published var machineTotals: [ToolTotal] = []
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
  @Published var startAtLogin: Bool {
    didSet {
      setStartAtLogin(enabled: startAtLogin)
    }
  }
  @Published var loginItemMessage: String?
  @Published var agentsviewPath: String {
    didSet {
      defaults.set(
        agentsviewPath, forKey: DefaultsKey.agentsviewPath
      )
    }
  }
  @Published var agentsviewServerURL: String {
    didSet {
      defaults.set(
        agentsviewServerURL, forKey: DefaultsKey.agentsviewServerURL
      )
    }
  }
  @Published private(set) var discoveredAgents: [UsageAgent]
  @Published private(set) var disabledAgentIDs: Set<String>

  @Published var refreshInterval: RefreshInterval {
    didSet {
      defaults.set(refreshInterval.rawValue, forKey: DefaultsKey.refreshInterval)
      scheduleTimer()
    }
  }

  private let defaults = UserDefaults.standard
  private let agentPreferences: AgentPreferences
  private let settingsWindowController = SettingsWindowController()
  private let welcomeWindowController = WelcomeWindowController()
  private var timer: DispatchSourceTimer?
  private var timeZoneObserver: NSObjectProtocol?
  private var timezoneRefreshState: UsageRefreshTimezoneState
  private var isUpdatingLoginItem = false
  private let store: UsageStore
  private let refreshService: UsageRefreshService

  init() {
    timezoneRefreshState = UsageRefreshTimezoneState(
      lastSuccessfulTimeZone: defaults.string(forKey: DefaultsKey.lastUsageTimeZone),
      lastInvalidatedTimeZone: defaults.string(forKey: DefaultsKey.lastUsageInvalidatedTimeZone))
    let agentPreferences = AgentPreferences(defaults: defaults)
    agentPreferences.migrateLegacyPreferences()
    self.agentPreferences = agentPreferences
    discoveredAgents = agentPreferences.loadDiscoveredAgents()
    disabledAgentIDs = agentPreferences.loadDisabledAgentIDs()
    let storedInterval = defaults.string(forKey: DefaultsKey.refreshInterval)
    if let storedInterval, let interval = RefreshInterval(rawValue: storedInterval) {
      refreshInterval = interval
    } else if let legacyMinutes = defaults.object(forKey: DefaultsKey.refreshMinutes) as? Double {
      refreshInterval = Self.intervalFromLegacy(minutes: legacyMinutes)
    } else {
      refreshInterval = .fifteenMinutes
    }
    let storedMode = defaults.string(forKey: DefaultsKey.maintenanceMode)
    maintenanceMode = MaintenanceMode(rawValue: storedMode ?? "") ?? .automatic
    if let storedMaintenance = defaults.object(forKey: DefaultsKey.lastMaintenanceAt) as? Double {
      lastMaintenanceAt = Date(timeIntervalSince1970: storedMaintenance)
    }

    agentsviewPath =
      defaults.string(forKey: DefaultsKey.agentsviewPath) ?? ""
    agentsviewServerURL =
      defaults.string(forKey: DefaultsKey.agentsviewServerURL) ?? ""
    startAtLogin = Self.currentLoginItemEnabled()

    if SMAppService.mainApp.status == .requiresApproval {
      loginItemMessage = "Enable VibePulse in System Settings > Login Items."
    }

    do {
      store = try UsageStore.defaultStore()
    } catch {
      store = try! UsageStore(path: ":memory:")
      statusMessage = "Database unavailable. Running without persistence."
    }
    refreshService = UsageRefreshService(fetcher: UsageFetcher(), store: store)
    timeZoneObserver = NotificationCenter.default.addObserver(
      forName: .NSSystemTimeZoneDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleSystemTimeZoneChange()
      }
    }

    let initialContext = UsageDateContext()
    if !timezoneRefreshState.shouldInvalidateCurrentDay(
      for: initialContext.timeZone.identifier)
    {
      reloadFromStore(context: initialContext)
    }
    scheduleTimer()
    refreshNow()
    runMaintenanceIfNeeded()
    DispatchQueue.main.async {
      self.showWelcomeIfNeeded()
    }
  }

  deinit {
    timer?.cancel()
    if let timeZoneObserver {
      NotificationCenter.default.removeObserver(timeZoneObserver)
    }
  }

  func refreshNow() {
    guard !isRefreshing else { return }

    isRefreshing = true
    statusMessage = nil

    let context = UsageDateContext()
    let invalidateCurrentDay = timezoneRefreshState.shouldInvalidateCurrentDay(
      for: context.timeZone.identifier)
    if invalidateCurrentDay {
      clearPublishedUsage()
    }

    DispatchQueue.global(qos: .background).async { [refreshService] in
      do {
        let result = try refreshService.refresh(
          context: context,
          invalidateCurrentDay: invalidateCurrentDay)
        let refreshTime = Date()

        DispatchQueue.main.async {
          guard UsageDateContext().timeZone.identifier == context.timeZone.identifier else {
            self.timezoneRefreshState.markTimezoneChange()
            self.isRefreshing = false
            self.refreshNow()
            return
          }

          self.discoveredAgents = result.discoveredAgents
          self.agentPreferences.saveDiscoveredAgents(result.discoveredAgents)
          if result.importErrors.isEmpty {
            self.statusMessage = nil
            self.lastUpdated = refreshTime
          } else {
            self.statusMessage = result.importErrors.joined(separator: " | ")
          }
          self.timezoneRefreshState.completeRefresh(
            for: context.timeZone.identifier,
            invalidatedCurrentDay: invalidateCurrentDay,
            hasImportErrors: !result.importErrors.isEmpty)
          self.persistTimezoneRefreshState()
          self.reloadFromStore(context: UsageDateContext())
          self.isRefreshing = false
        }
      } catch {
        DispatchQueue.main.async {
          let contextStillCurrent =
            UsageDateContext().timeZone.identifier == context.timeZone.identifier
          if !contextStillCurrent {
            self.timezoneRefreshState.markTimezoneChange()
          }
          self.statusMessage = error.localizedDescription
          if contextStillCurrent {
            self.reloadFromStoreIfTimezoneReady()
          }
          self.isRefreshing = false
          if !contextStillCurrent {
            self.refreshNow()
          }
        }
      }
    }
  }

  private func handleSystemTimeZoneChange() {
    clearPublishedUsage()
    timezoneRefreshState.markTimezoneChange()
    refreshNow()
  }

  private func persistTimezoneRefreshState() {
    if let lastSuccessfulTimeZone = timezoneRefreshState.lastSuccessfulTimeZone {
      defaults.set(lastSuccessfulTimeZone, forKey: DefaultsKey.lastUsageTimeZone)
    }
    if let lastInvalidatedTimeZone = timezoneRefreshState.lastInvalidatedTimeZone {
      defaults.set(
        lastInvalidatedTimeZone,
        forKey: DefaultsKey.lastUsageInvalidatedTimeZone)
    }
  }

  private func clearPublishedUsage() {
    menuTotalText = Formatters.currencyString(0)
    hourlySeries = []
    cumulativeSeries = []
    dailySeries = []
    toolTotals = []
    modelCumulativeSeries = []
    modelDailySeries = []
    modelTotals = []
    machineCumulativeSeries = []
    machineDailySeries = []
    machineTotals = []
    lastUpdated = nil
  }

  private func showWelcomeIfNeeded() {
    if !defaults.bool(forKey: DefaultsKey.welcomeKey) {
      welcomeWindowController.show(model: self) {
        self.defaults.set(true, forKey: DefaultsKey.welcomeKey)
      }
    }
  }

  func openSettings() {
    settingsWindowController.show(model: self)
  }

  var hasDiscoveryCache: Bool {
    agentPreferences.hasDiscoveryCache
  }

  func isAgentEnabled(_ agent: UsageAgent) -> Bool {
    !disabledAgentIDs.contains(agent.rawValue)
  }

  func setAgent(_ agent: UsageAgent, enabled: Bool) {
    if enabled {
      disabledAgentIDs.remove(agent.rawValue)
    } else {
      disabledAgentIDs.insert(agent.rawValue)
    }
    agentPreferences.saveDisabledAgentIDs(disabledAgentIDs)
    reloadFromStoreIfTimezoneReady()
  }

  private var activeTools: [UsageAgent] {
    AgentPreferences.enabledAgents(
      from: discoveredAgents,
      disabledAgentIDs: disabledAgentIDs)
  }

  private func reloadFromStore(context: UsageDateContext = UsageDateContext()) {
    let tools = activeTools
    let startOfDay = context.startOfToday
    let now = context.now
    var hourlyPoints: [UsageSeriesPoint] = []

    for tool in tools {
      let samples = store.fetchSamples(tool: tool, from: startOfDay, to: now).sorted {
        $0.recordedAt < $1.recordedAt
      }
      hourlyPoints.append(
        contentsOf: HourlyUsageInferer.inferPoints(
          tool: tool,
          samples: samples,
          startOfDay: startOfDay,
          end: now,
          calendar: context.calendar))
    }

    hourlySeries = hourlyPoints.sorted { $0.date < $1.date }
    var cumulativePoints: [UsageSeriesPoint] = []

    for tool in tools {
      let samples = store.fetchSamples(tool: tool, from: startOfDay, to: now).sorted {
        $0.recordedAt < $1.recordedAt
      }
      cumulativePoints.append(
        contentsOf: samples.map {
          UsageSeriesPoint(tool: tool, date: $0.recordedAt, cost: $0.totalCost)
        })
    }

    cumulativeSeries = cumulativePoints.sorted { $0.date < $1.date }

    let modelSamples = store.fetchModelSamples(tools: tools, from: startOfDay, to: now)
    modelCumulativeSeries = UsageSeriesAggregation.cumulativeModelSeries(from: modelSamples)
    let machineSamples = store.fetchMachineSamples(tools: tools, from: startOfDay, to: now)
    machineCumulativeSeries = UsageSeriesAggregation.cumulativeMachineSeries(from: machineSamples)

    let sinceKey = context.usageWindowStartKey
    let rollups = store.fetchDailyRollups(
      since: sinceKey,
      through: context.todayKey,
      timeZone: context.timeZone)
    dailySeries = rollups.compactMap { rollup in
      guard
        tools.contains(rollup.tool),
        let date = DateHelper.date(fromKey: rollup.dateKey, in: context.timeZone)
      else {
        return nil
      }
      return UsageSeriesPoint(tool: rollup.tool, date: date, cost: rollup.totalCost)
    }

    let modelRollups = store.fetchModelDailyRollups(
      since: sinceKey,
      through: context.todayKey,
      tools: tools,
      timeZone: context.timeZone)
    modelDailySeries = aggregateModelDailySeries(
      modelRollups,
      timeZone: context.timeZone)
    let machineRollups = store.fetchMachineDailyRollups(
      since: sinceKey,
      through: context.todayKey,
      tools: tools,
      timeZone: context.timeZone)
    machineDailySeries = UsageSeriesAggregation.dailyMachineSeries(
      from: machineRollups,
      timeZone: context.timeZone)

    var totals: [ToolTotal] = []
    for tool in tools {
      let dailyTotal = store.dailyTotal(for: context.todayKey, tool: tool)
      let sampleTotal = store.latestSample(
        tool: tool,
        from: context.startOfToday,
        to: context.startOfNextDay)?.totalCost
      let totalCost = dailyTotal ?? sampleTotal ?? 0
      totals.append(ToolTotal(tool: tool, totalCost: totalCost))
    }
    toolTotals = totals
    modelTotals = aggregateModelTotals(modelRollups, todayKey: context.todayKey)
    machineTotals = UsageSeriesAggregation.machineTotals(
      from: machineRollups, dateKey: context.todayKey)
    let combined = totals.reduce(0) { $0 + $1.totalCost }
    menuTotalText = Formatters.currencyString(combined)
  }

  private func reloadFromStoreIfTimezoneReady() {
    let context = UsageDateContext()
    guard !timezoneRefreshState.shouldDeferStoreReload(for: context.timeZone.identifier) else {
      return
    }
    reloadFromStore(context: context)
  }

  private func aggregateModelDailySeries(
    _ rollups: [ModelDailyRollup],
    timeZone: TimeZone
  ) -> [UsageSeriesPoint] {
    var totalsByDateAndModel: [ModelDailyKey: Double] = [:]
    for rollup in rollups {
      let key = ModelDailyKey(dateKey: rollup.dateKey, modelName: rollup.modelName)
      totalsByDateAndModel[key, default: 0] += rollup.totalCost
    }

    return totalsByDateAndModel.compactMap { key, totalCost in
      guard let date = DateHelper.date(fromKey: key.dateKey, in: timeZone) else {
        return nil
      }
      return UsageSeriesPoint(series: .model(key.modelName), date: date, cost: totalCost)
    }
    .sorted {
      if $0.date == $1.date {
        return $0.series.sortKey < $1.series.sortKey
      }
      return $0.date < $1.date
    }
  }

  private func aggregateModelTotals(
    _ rollups: [ModelDailyRollup],
    todayKey: String
  ) -> [ToolTotal] {
    var totalsByModel: [String: Double] = [:]
    for rollup in rollups where rollup.dateKey == todayKey {
      totalsByModel[rollup.modelName, default: 0] += rollup.totalCost
    }

    return totalsByModel.map { modelName, totalCost in
      ToolTotal(series: .model(modelName), totalCost: totalCost)
    }
    .sorted { $0.series.sortKey < $1.series.sortKey }
  }

  private struct ModelDailyKey: Hashable {
    let dateKey: String
    let modelName: String
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
        let modelDeltaUpdated = try store.backfillModelSampleDeltas()
        let machineDeltaUpdated = try store.backfillMachineSampleDeltas()
        let dateUpdated = try store.storedAgents().reduce(0) { count, tool in
          count + (try store.normalizeDailyRollupDates(for: tool))
            + (try store.normalizeModelDailyRollupDates(for: tool))
            + (try store.normalizeMachineDailyRollupDates(for: tool))
        }
        let message =
          "Maintenance complete. Updated \(deltaUpdated + modelDeltaUpdated + machineDeltaUpdated) snapshots, normalized \(dateUpdated) daily totals."
        let now = Date()
        DispatchQueue.main.async {
          self.maintenanceMessage = message
          self.lastMaintenanceAt = now
          self.defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.lastMaintenanceAt)
          self.reloadFromStoreIfTimezoneReady()
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

  private static func intervalFromLegacy(minutes: Double) -> RefreshInterval {
    switch minutes {
    case ..<10:
      return .fiveMinutes
    case ..<30:
      return .fifteenMinutes
    case ..<120:
      return .oneHour
    case ..<600:
      return .fourHours
    default:
      return .oneDay
    }
  }

  private static func currentLoginItemEnabled() -> Bool {
    switch SMAppService.mainApp.status {
    case .enabled, .requiresApproval:
      return true
    default:
      return false
    }
  }

  private func setStartAtLogin(enabled: Bool) {
    guard !isUpdatingLoginItem else { return }
    isUpdatingLoginItem = true
    defer { isUpdatingLoginItem = false }

    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      if SMAppService.mainApp.status == .requiresApproval {
        loginItemMessage = "Enable VibePulse in System Settings > Login Items."
      } else {
        loginItemMessage = nil
      }
    } catch {
      loginItemMessage = "Login item update failed: \(error.localizedDescription)"
      startAtLogin = Self.currentLoginItemEnabled()
    }
  }

  private func scheduleTimer() {
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
    let intervalSeconds = max(60, refreshInterval.seconds)
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
    static let welcomeKey = "hasSeenWelcome"
    static let refreshMinutes = "refreshMinutes"
    static let refreshInterval = "refreshInterval"
    static let agentsviewPath = "agentsviewPath"
    static let agentsviewServerURL = "agentsviewServerURL"
    static let maintenanceMode = "maintenanceMode"
    static let lastMaintenanceAt = "lastMaintenanceAt"
    static let lastUsageTimeZone = "lastUsageTimeZone"
    static let lastUsageInvalidatedTimeZone = "lastUsageInvalidatedTimeZone"
  }
}
