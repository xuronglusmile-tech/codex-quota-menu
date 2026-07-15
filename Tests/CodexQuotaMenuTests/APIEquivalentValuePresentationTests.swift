import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct APIEquivalentValuePresentationTests {
    @Test
    func testFiveMillionTokenPresentationUsesApprovedScaleAndCopy() {
        let usage = MonthlyUsage(
            monthStart: .distantPast,
            tokens: 5_000_000,
            fetchedAt: .distantPast
        )
        let value = APIEquivalentValuePresentation(usage: usage)

        #expect(value.rangeText == "$13.25～$41.00")
        #expect(value.tokenText == "5.00M tokens")
        #expect(abs(value.lowerFraction - 0.053) < 0.000_001)
        #expect(abs(value.upperFraction - 0.164) < 0.000_001)
        #expect(value.plusFraction == 0.08)
        #expect(value.proFraction == 0.80)
        #expect(value.statusText == "可能达到 Plus $20 · 未达到 Pro $200")
    }

    @Test
    func testTrackFractionsClipAtTwoHundredFiftyWithoutClippingText() {
        let usage = MonthlyUsage(
            monthStart: .distantPast,
            tokens: 100_000_000,
            fetchedAt: .distantPast
        )
        let value = APIEquivalentValuePresentation(usage: usage)

        #expect(value.upperFraction == 1)
        #expect(value.rangeText == "$265.00～$820.00")
    }

    @Test
    func testZeroTokensShowZeroRangeAndEmptyFill() {
        let usage = MonthlyUsage(
            monthStart: .distantPast,
            tokens: 0,
            fetchedAt: .distantPast
        )
        let value = APIEquivalentValuePresentation(usage: usage)

        #expect(value.rangeText == "$0.00～$0.00")
        #expect(value.lowerFraction == 0)
        #expect(value.upperFraction == 0)
        #expect(value.statusText == "未达到 Plus $20 · 未达到 Pro $200")
    }
}
