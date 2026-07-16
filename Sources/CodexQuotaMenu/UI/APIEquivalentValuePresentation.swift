import Foundation

struct APIEquivalentValuePresentation: Equatable, Sendable {
    static let trackMaximum = Decimal(250)
    static let plusBenchmark = Decimal(20)
    static let proBenchmark = Decimal(200)

    let rangeText: String
    let tokenText: String
    let statusText: String
    let lowerText: String
    let upperText: String
    let lowerFraction: Double
    let upperFraction: Double
    let plusFraction: Double
    let proFraction: Double

    init(usage: MonthlyUsage) {
        let scenarios = APIEquivalentValueEstimator.estimate(tokens: usage.tokens)
        let formattedLower = Self.dollars(scenarios.cachedHeavyUSD)
        let formattedUpper = Self.dollars(scenarios.outputHeavyUSD)
        lowerText = formattedLower
        upperText = formattedUpper
        rangeText = "\(formattedLower)～\(formattedUpper)"
        tokenText = Self.tokens(usage.tokens)
        lowerFraction = Self.fraction(scenarios.cachedHeavyUSD)
        upperFraction = Self.fraction(scenarios.outputHeavyUSD)
        plusFraction = Self.fraction(Self.plusBenchmark)
        proFraction = Self.fraction(Self.proBenchmark)
        statusText = [
            Self.status(
                APIEquivalentValueEstimator.position(
                    scenarios: scenarios,
                    benchmark: Self.plusBenchmark
                ),
                name: "Plus $20"
            ),
            Self.status(
                APIEquivalentValueEstimator.position(
                    scenarios: scenarios,
                    benchmark: Self.proBenchmark
                ),
                name: "Pro $200"
            )
        ].joined(separator: " · ")
    }

    private static func fraction(_ value: Decimal) -> Double {
        let raw = NSDecimalNumber(decimal: value / trackMaximum).doubleValue
        return min(max(raw, 0), 1)
    }

    private static func dollars(_ value: Decimal) -> String {
        String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            NSDecimalNumber(decimal: value).doubleValue
        )
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

    private static func status(_ position: BenchmarkPosition, name: String) -> String {
        switch position {
        case .below: return "未达到 \(name)"
        case .crossing: return "可能达到 \(name)"
        case .reached: return "已达到 \(name)"
        }
    }
}
