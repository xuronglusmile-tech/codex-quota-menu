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
    func testFixedSolScenarios(
        tokens: Int64,
        cachedHeavy: Decimal,
        outputHeavy: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.estimate(tokens: tokens) == .init(
            cachedHeavyUSD: cachedHeavy,
            outputHeavyUSD: outputHeavy
        ))
    }

    @Test
    func testNegativeTokensCannotProduceNegativeScenarioValues() {
        #expect(APIEquivalentValueEstimator.estimate(tokens: -1) == .init(
            cachedHeavyUSD: 0,
            outputHeavyUSD: 0
        ))
    }

    @Test(arguments: [Decimal(20), Decimal(200)])
    func testTransitionalBenchmarkClassificationRemainsStable(
        benchmark: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.position(
            scenarios: .init(
                cachedHeavyUSD: benchmark - Decimal(string: "6.75")!,
                outputHeavyUSD: benchmark - Decimal(string: "0.01")!
            ),
            benchmark: benchmark
        ) == .below)
        #expect(APIEquivalentValueEstimator.position(
            scenarios: .init(
                cachedHeavyUSD: benchmark - Decimal(string: "6.75")!,
                outputHeavyUSD: benchmark + Decimal(21)
            ),
            benchmark: benchmark
        ) == .crossing)
        #expect(APIEquivalentValueEstimator.position(
            scenarios: .init(
                cachedHeavyUSD: benchmark,
                outputHeavyUSD: benchmark + Decimal(21)
            ),
            benchmark: benchmark
        ) == .reached)
    }
}
