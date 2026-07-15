import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct MonthlyUsageMapperTests {
    @Test
    func testSumsOnlyCurrentMonthDateOnlyBuckets() throws {
        let result = try MonthlyUsageMapper.map(
            buckets: [
                .init(startDate: "2026-06-30", tokens: 7),
                .init(startDate: "2026-07-01", tokens: 2_000_000),
                .init(startDate: "2026-07-16", tokens: 3_000_000),
                .init(startDate: "2026-08-01", tokens: 11)
            ],
            now: Self.date(year: 2026, month: 7, day: 16),
            calendar: Self.calendar()
        )

        #expect(result.tokens == 5_000_000)
        #expect(Self.calendar().component(.day, from: result.monthStart) == 1)
    }

    @Test
    func testEmptyBucketsMeanZero() throws {
        let result = try MonthlyUsageMapper.map(
            buckets: [],
            now: Self.date(year: 2026, month: 7, day: 16),
            calendar: Self.calendar()
        )

        #expect(result.tokens == 0)
    }

    @Test(arguments: [
        [WireDailyUsageBucket(startDate: "not-a-date", tokens: 1)],
        [WireDailyUsageBucket(startDate: "2026-02-30", tokens: 1)],
        [WireDailyUsageBucket(startDate: "2026-07-01", tokens: -1)]
    ])
    func testInvalidBucketMakesUsageUnavailable(buckets: [WireDailyUsageBucket]) {
        #expect(throws: MonthlyUsageMappingError.self) {
            try MonthlyUsageMapper.map(
                buckets: buckets,
                now: Self.date(year: 2026, month: 7, day: 16),
                calendar: Self.calendar()
            )
        }
    }

    @Test
    func testCheckedSumRejectsOverflow() {
        do {
            _ = try MonthlyUsageMapper.map(
                buckets: [
                    .init(startDate: "2026-07-01", tokens: Int64.max),
                    .init(startDate: "2026-07-02", tokens: 1)
                ],
                now: Self.date(year: 2026, month: 7, day: 16),
                calendar: Self.calendar()
            )
            Issue.record("Expected checked-sum overflow")
        } catch let error as MonthlyUsageMappingError {
            #expect(error == .overflow)
        } catch {
            Issue.record("Expected MonthlyUsageMappingError.overflow, got \(error)")
        }
    }

    @Test
    func testYearBoundaryAndLeapDayRemainDateOnly() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let january = try MonthlyUsageMapper.map(
            buckets: [
                .init(startDate: "2026-12-31", tokens: 1),
                .init(startDate: "2027-01-01", tokens: 2)
            ],
            now: utc.date(from: DateComponents(year: 2027, month: 1, day: 15))!,
            calendar: utc
        )
        let leapFebruary = try MonthlyUsageMapper.map(
            buckets: [.init(startDate: "2028-02-29", tokens: 3)],
            now: utc.date(from: DateComponents(year: 2028, month: 2, day: 29))!,
            calendar: utc
        )

        #expect(january.tokens == 2)
        #expect(leapFebruary.tokens == 3)
    }

    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day))!
    }
}
