import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct APIEquivalentValuePresentationTests {
    @Test
    func testFiveMillionTokensUseFiftyDollarScale() {
        let value = presentation(tokens: 5_000_000)

        #expect(value.rangeText == "$13.25～$41.00")
        #expect(value.cachedHeavyText == "$13.25")
        #expect(value.outputHeavyText == "$41.00")
        #expect(value.tokenText == "5.00M tokens")
        #expect(value.trackMidpointText == "$25")
        #expect(value.trackMaximumText == "$50")
        #expect(abs(value.cachedHeavyFraction - 0.265) < 0.000_001)
        #expect(abs(value.outputHeavyFraction - 0.82) < 0.000_001)
    }

    @Test
    func testZeroTokensUseMinimumScaleAndEmptyFills() {
        let value = presentation(tokens: 0)

        #expect(value.rangeText == "$0.00～$0.00")
        #expect(value.trackMidpointText == "$25")
        #expect(value.trackMaximumText == "$50")
        #expect(value.cachedHeavyFraction == 0)
        #expect(value.outputHeavyFraction == 0)
    }

    @Test(arguments: [
        (Decimal(string: "41")!, Decimal(50)),
        (Decimal(string: "50")!, Decimal(50)),
        (Decimal(string: "51")!, Decimal(100)),
        (Decimal(string: "820")!, Decimal(1_000)),
        (Decimal(string: "4032.23")!, Decimal(5_000))
    ])
    func testNiceTrackMaximumBoundaries(value: Decimal, expected: Decimal) {
        #expect(APIEquivalentValuePresentation.niceTrackMaximum(for: value) == expected)
    }

    @Test
    func testCurrentScaleUsageGetsGroupedFiveThousandDollarTrackWithoutSaturation() {
        let value = presentation(tokens: 491_735_161)

        #expect(value.rangeText == "$1303.10～$4032.23")
        #expect(value.trackMidpointText == "$2,500")
        #expect(value.trackMaximumText == "$5,000")
        #expect(value.cachedHeavyFraction > 0)
        #expect(value.cachedHeavyFraction < value.outputHeavyFraction)
        #expect(value.outputHeavyFraction < 1)
    }

    private func presentation(tokens: Int64) -> APIEquivalentValuePresentation {
        APIEquivalentValuePresentation(usage: MonthlyUsage(
            monthStart: .distantPast,
            tokens: tokens,
            fetchedAt: .distantPast
        ))
    }
}
