import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaProgressPresentationTests {
    @Test(arguments: [
        (9, QuotaProgressBand.critical),
        (10, QuotaProgressBand.warning),
        (19, QuotaProgressBand.warning),
        (20, QuotaProgressBand.normal),
        (100, QuotaProgressBand.normal)
    ])
    func testWeeklyBoundaries(remaining: Int, expected: QuotaProgressBand) {
        #expect(QuotaProgressPresentation.band(
            remainingPercent: remaining,
            durationMinutes: 10_080
        ) == expected)
    }

    @Test
    func testNonWeeklyWindowRetainsExistingTint() {
        #expect(QuotaProgressPresentation.band(
            remainingPercent: 5,
            durationMinutes: 300
        ) == nil)
    }
}
