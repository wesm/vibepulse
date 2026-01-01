import Foundation

enum Formatters {
  static let currency: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter
  }()

  static let percent: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .percent
    formatter.maximumFractionDigits = 1
    formatter.minimumFractionDigits = 0
    return formatter
  }()

  static func currencyString(_ value: Double) -> String {
    currency.string(from: NSNumber(value: value)) ?? "$0.00"
  }

  static func percentString(_ value: Double) -> String {
    percent.string(from: NSNumber(value: value)) ?? "0%"
  }
}
