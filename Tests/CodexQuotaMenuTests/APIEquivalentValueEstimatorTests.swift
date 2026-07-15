import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct APIEquivalentValueEstimatorTests {
    @Test(arguments: [
        (Int64(0), Decimal(string: "0")!, Decimal(string: "0")!),
        (Int64(1_000_000), Decimal(string: "2.65")!, Decimal(string: "8.20")!),
        (Int64(5_000_000), Decimal(string: "13.25")!, Decimal(string: "41.00")!)
    ])
    func testFixedScenarioRange(
        tokens: Int64,
        lower: Decimal,
        upper: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.estimate(tokens: tokens) == .init(
            lowerUSD: lower,
            upperUSD: upper
        ))
    }

    @Test(arguments: [Decimal(20), Decimal(200)])
    func testBenchmarkPositionsAtPlusAndPro(benchmark: Decimal) {
        #expect(APIEquivalentValueEstimator.position(
            range: .init(
                lowerUSD: benchmark - Decimal(string: "6.75")!,
                upperUSD: benchmark - Decimal(string: "0.01")!
            ),
            benchmark: benchmark
        ) == .below)
        #expect(APIEquivalentValueEstimator.position(
            range: .init(
                lowerUSD: benchmark - Decimal(string: "6.75")!,
                upperUSD: benchmark + Decimal(21)
            ),
            benchmark: benchmark
        ) == .crossing)
        #expect(APIEquivalentValueEstimator.position(
            range: .init(lowerUSD: benchmark, upperUSD: benchmark + Decimal(21)),
            benchmark: benchmark
        ) == .reached)
    }
}
