import Foundation

struct APIEquivalentValueRange: Equatable, Sendable {
    let lowerUSD: Decimal
    let upperUSD: Decimal
}

enum BenchmarkPosition: Equatable, Sendable {
    case below
    case crossing
    case reached
}

enum APIEquivalentValueEstimator {
    static let lowerRatePerMillion = Decimal(string: "2.65")!
    static let upperRatePerMillion = Decimal(string: "8.20")!

    static func estimate(tokens: Int64) -> APIEquivalentValueRange {
        let millions = Decimal(max(tokens, 0)) / Decimal(1_000_000)
        return APIEquivalentValueRange(
            lowerUSD: millions * lowerRatePerMillion,
            upperUSD: millions * upperRatePerMillion
        )
    }

    static func position(
        range: APIEquivalentValueRange,
        benchmark: Decimal
    ) -> BenchmarkPosition {
        if range.upperUSD < benchmark { return .below }
        if range.lowerUSD >= benchmark { return .reached }
        return .crossing
    }
}
