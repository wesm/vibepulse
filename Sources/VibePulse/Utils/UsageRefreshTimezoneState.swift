import Foundation

struct UsageRefreshTimezoneState: Equatable, Sendable {
  var lastSuccessfulTimeZone: String?
  var lastInvalidatedTimeZone: String?
  var pendingInvalidation: Bool

  init(
    lastSuccessfulTimeZone: String? = nil,
    lastInvalidatedTimeZone: String? = nil,
    pendingInvalidation: Bool = false
  ) {
    self.lastSuccessfulTimeZone = lastSuccessfulTimeZone
    self.lastInvalidatedTimeZone = lastInvalidatedTimeZone
    self.pendingInvalidation = pendingInvalidation
  }

  func shouldInvalidateCurrentDay(for timeZoneIdentifier: String) -> Bool {
    let lastProcessedTimeZone = lastInvalidatedTimeZone ?? lastSuccessfulTimeZone
    guard let lastProcessedTimeZone else { return true }
    return pendingInvalidation || lastProcessedTimeZone != timeZoneIdentifier
  }

  func shouldDeferStoreReload(for timeZoneIdentifier: String) -> Bool {
    shouldInvalidateCurrentDay(for: timeZoneIdentifier)
  }

  mutating func markTimezoneChange() {
    pendingInvalidation = true
  }

  mutating func completeRefresh(
    for timeZoneIdentifier: String,
    invalidatedCurrentDay: Bool,
    hasImportErrors: Bool
  ) {
    if invalidatedCurrentDay {
      lastInvalidatedTimeZone = timeZoneIdentifier
      pendingInvalidation = false
    }
    if !hasImportErrors {
      lastSuccessfulTimeZone = timeZoneIdentifier
    }
  }
}
