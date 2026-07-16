import Foundation

struct APIEquivalentValueScenarios: Equatable, Sendable {
    let cachedHeavyUSD: Decimal
    let outputHeavyUSD: Decimal
}

enum APIEquivalentValueEstimator {
    static let cachedHeavyRatePerMillion = Decimal(string: "2.65")!
    static let outputHeavyRatePerMillion = Decimal(string: "8.20")!

    static func estimate(tokens: Int64) -> APIEquivalentValueScenarios {
        let millions = Decimal(max(tokens, 0)) / Decimal(1_000_000)
        return APIEquivalentValueScenarios(
            cachedHeavyUSD: millions * cachedHeavyRatePerMillion,
            outputHeavyUSD: millions * outputHeavyRatePerMillion
        )
    }
}
