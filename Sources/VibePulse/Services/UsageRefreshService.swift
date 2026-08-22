import Foundation

struct UsageRefreshResult: Sendable {
  let discoveredAgents: [UsageAgent]
  let importErrors: [String]
}

final class UsageRefreshService: @unchecked Sendable {
  private let fetcher: UsageFetching
  private let store: UsageStore

  init(fetcher: UsageFetching, store: UsageStore) {
    self.fetcher = fetcher
    self.store = store
  }

  func refresh(
    context: UsageDateContext,
    invalidateCurrentDay: Bool = false
  ) throws -> UsageRefreshResult {
    if invalidateCurrentDay {
      try store.deleteCurrentDaySamples(using: context)
      try store.deleteRefreshWindowRollups(using: context)
    }

    let agents = try fetcher.discoverAgents(using: context).sorted()
    var errors: [String] = []

    for agent in agents {
      do {
        let totals = try fetcher.fetchDailyTotals(for: agent, using: context)
        try store.replaceDailyTotals(
          tool: agent,
          totals: totals,
          dateContext: context)
        if let todayTotal = totals.first(where: {
          DateHelper.normalizedDateKey(from: $0.dateKey, in: context.timeZone)
            == context.todayKey
        }) {
          try store.insertSample(
            tool: agent,
            totalCost: todayTotal.cost,
            recordedAt: context.now,
            dateContext: context)
          if let modelBreakdowns = todayTotal.modelBreakdowns {
            try store.insertModelSamplesForRefresh(
              tool: agent,
              modelBreakdowns: modelBreakdowns,
              recordedAt: context.now,
              dateContext: context)
          }
          if let machineBreakdowns = todayTotal.machineBreakdowns {
            try store.insertMachineSamplesForRefresh(
              tool: agent,
              machineBreakdowns: machineBreakdowns,
              recordedAt: context.now,
              dateContext: context)
          }
        }
      } catch {
        errors.append("\(agent.displayName): \(error.localizedDescription)")
      }
    }

    return UsageRefreshResult(
      discoveredAgents: agents,
      importErrors: errors)
  }
}
