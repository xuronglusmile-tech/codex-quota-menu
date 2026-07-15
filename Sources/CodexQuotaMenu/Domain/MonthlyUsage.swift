import Foundation

struct MonthlyUsage: Codable, Equatable, Sendable {
    let monthStart: Date
    let tokens: Int64
    let fetchedAt: Date
}

enum MonthlyUsageMappingError: Error, Equatable {
    case invalidCalendar
    case invalidStartDate(String)
    case negativeTokens(Int64)
    case overflow
}

enum MonthlyUsageMapper {
    static func map(
        buckets: [WireDailyUsageBucket],
        now: Date,
        calendar: Calendar
    ) throws -> MonthlyUsage {
        guard let interval = calendar.dateInterval(of: .month, for: now) else {
            throw MonthlyUsageMappingError.invalidCalendar
        }

        var total: Int64 = 0
        for bucket in buckets {
            guard bucket.tokens >= 0 else {
                throw MonthlyUsageMappingError.negativeTokens(bucket.tokens)
            }
            let date = try dateOnly(bucket.startDate, calendar: calendar)
            guard date >= interval.start, date < interval.end else { continue }
            let (next, overflow) = total.addingReportingOverflow(bucket.tokens)
            guard !overflow else { throw MonthlyUsageMappingError.overflow }
            total = next
        }

        return MonthlyUsage(
            monthStart: interval.start,
            tokens: total,
            fetchedAt: now
        )
    }

    private static func dateOnly(_ value: String, calendar: Calendar) throws -> Date {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw MonthlyUsageMappingError.invalidStartDate(value)
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            throw MonthlyUsageMappingError.invalidStartDate(value)
        }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year,
              normalized.month == month,
              normalized.day == day else {
            throw MonthlyUsageMappingError.invalidStartDate(value)
        }
        return date
    }
}
