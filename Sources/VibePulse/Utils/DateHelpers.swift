import Foundation

enum DateHelper {
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let codexFormatters: [DateFormatter] = {
    let formats = [
      "MMM d, yyyy",
      "MMMM d, yyyy",
      "d MMM yyyy",
      "d MMMM yyyy",
      "yyyy/MM/dd",
      "yyyy.MM.dd",
    ]
    return formats.map { format in
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone.current
      formatter.dateFormat = format
      return formatter
    }
  }()

  static func dateKey(for date: Date) -> String {
    dateFormatter.string(from: date)
  }

  static func date(fromKey key: String) -> Date? {
    dateFormatter.date(from: key)
  }

  static func normalizedDateKey(from raw: String) -> String? {
    if let date = dateFormatter.date(from: raw) {
      return dateFormatter.string(from: date)
    }

    for formatter in codexFormatters {
      if let date = formatter.date(from: raw) {
        return dateFormatter.string(from: date)
      }
    }

    return nil
  }

  static func startOfToday() -> Date {
    Calendar.current.startOfDay(for: Date())
  }

  static func dateKeyDaysAgo(_ days: Int) -> String {
    let base = Calendar.current.startOfDay(for: Date())
    let target = Calendar.current.date(byAdding: .day, value: -days, to: base) ?? base
    return dateKey(for: target)
  }
}
