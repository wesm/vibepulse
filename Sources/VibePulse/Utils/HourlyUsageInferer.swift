import Foundation

enum HourlyUsageInferer {
  static func inferPoints(tool: UsageTool, samples: [UsageSample], startOfDay: Date, end: Date)
    -> [UsageSeriesPoint]
  {
    guard startOfDay < end else { return [] }
    guard !samples.isEmpty else { return [] }

    let calendar = Calendar.current
    let endHour = calendar.component(.hour, from: end)
    var hourlyTotals = Array(repeating: 0.0, count: endHour + 1)

    var previousTime = startOfDay

    for sample in samples {
      let currentTime = max(sample.recordedAt, previousTime)
      let delta = max(0, sample.deltaCost)

      if delta > 0 {
        if currentTime > previousTime {
          let totalSeconds = currentTime.timeIntervalSince(previousTime)
          var cursor = previousTime

          while cursor < currentTime {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? currentTime
            let sliceEnd = min(currentTime, nextHour)
            let sliceSeconds = sliceEnd.timeIntervalSince(cursor)
            let portion = delta * (sliceSeconds / totalSeconds)
            let hourIndex = calendar.component(.hour, from: hourStart)
            if hourIndex >= 0 && hourIndex < hourlyTotals.count {
              hourlyTotals[hourIndex] += portion
            }
            cursor = sliceEnd
          }
        } else {
          let hourIndex = calendar.component(.hour, from: currentTime)
          if hourIndex >= 0 && hourIndex < hourlyTotals.count {
            hourlyTotals[hourIndex] += delta
          }
        }
      }

      previousTime = currentTime
    }

    var points: [UsageSeriesPoint] = []
    for hour in 0...endHour {
      if let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay) {
        points.append(UsageSeriesPoint(tool: tool, date: date, cost: hourlyTotals[hour]))
      }
    }

    return points
  }
}
