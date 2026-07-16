import Foundation

struct APIEquivalentValuePresentation: Equatable, Sendable {
    let rangeText: String
    let tokenText: String
    let cachedHeavyText: String
    let outputHeavyText: String
    let trackMidpointText: String
    let trackMaximumText: String
    let cachedHeavyFraction: Double
    let outputHeavyFraction: Double

    init(usage: MonthlyUsage) {
        let scenarios = APIEquivalentValueEstimator.estimate(tokens: usage.tokens)
        let trackMaximum = Self.niceTrackMaximum(for: scenarios.outputHeavyUSD)
        let formattedCachedHeavy = Self.dollars(scenarios.cachedHeavyUSD)
        let formattedOutputHeavy = Self.dollars(scenarios.outputHeavyUSD)

        cachedHeavyText = formattedCachedHeavy
        outputHeavyText = formattedOutputHeavy
        rangeText = "\(formattedCachedHeavy)～\(formattedOutputHeavy)"
        tokenText = Self.tokens(usage.tokens)
        trackMidpointText = Self.scaleDollars(trackMaximum / 2)
        trackMaximumText = Self.scaleDollars(trackMaximum)
        cachedHeavyFraction = Self.fraction(
            scenarios.cachedHeavyUSD,
            maximum: trackMaximum
        )
        outputHeavyFraction = Self.fraction(
            scenarios.outputHeavyUSD,
            maximum: trackMaximum
        )
    }

    static func niceTrackMaximum(for value: Decimal) -> Decimal {
        let minimum = Decimal(50)
        guard value > minimum else { return minimum }

        var power = Decimal(100)
        while true {
            for multiplier in [Decimal(1), Decimal(2), Decimal(5)] {
                let candidate = power * multiplier
                if value <= candidate { return candidate }
            }
            power *= 10
        }
    }

    private static func fraction(_ value: Decimal, maximum: Decimal) -> Double {
        let raw = NSDecimalNumber(decimal: value / maximum).doubleValue
        return min(max(raw, 0), 1)
    }

    private static func dollars(_ value: Decimal) -> String {
        String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            NSDecimalNumber(decimal: value).doubleValue
        )
    }

    private static func scaleDollars(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        let number = formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
        return "$\(number)"
    }

    private static func tokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(
                format: "%.2fM tokens",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(value) / 1_000_000
            )
        }
        if value >= 1_000 {
            return String(
                format: "%.2fK tokens",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(value) / 1_000
            )
        }
        return "\(value) tokens"
    }
}
