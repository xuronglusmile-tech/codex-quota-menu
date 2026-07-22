import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct MenuBarPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_784_038_400)

    @Test
    func testUsesWeeklyWindowInsteadOfMoreConstrainedShortWindow() {
        let presentation = MenuBarPresentation.make(for: .fresh(snapshot(windows: [
            QuotaWindow(
                id: "short",
                label: "5 小时额度",
                usedPercent: 95,
                durationMinutes: 300,
                resetsAt: nil
            ),
            QuotaWindow(
                id: "weekly",
                label: "每周额度",
                usedPercent: 69,
                durationMinutes: 10_080,
                resetsAt: nil
            )
        ])))

        #expect(presentation.text == "31%")
        #expect(presentation.fillFraction == 0.31)
        #expect(presentation.band == .normal)
        #expect(presentation.accessibilityLabel == "每周剩余额度 31%")
    }

    @Test(arguments: [
        (20, QuotaProgressBand.normal),
        (19, QuotaProgressBand.warning),
        (10, QuotaProgressBand.warning),
        (9, QuotaProgressBand.critical)
    ])
    func testWeeklyColorBoundaries(
        remainingPercent: Int,
        expectedBand: QuotaProgressBand
    ) {
        let window = QuotaWindow(
            id: "weekly",
            label: "每周额度",
            usedPercent: 100 - remainingPercent,
            durationMinutes: 10_080,
            resetsAt: nil
        )

        #expect(
            MenuBarPresentation.make(for: .fresh(snapshot(windows: [window]))).band
                == expectedBand
        )
    }

    @Test
    func testClampsPercentageAndFillFraction() {
        let above = QuotaWindow(
            id: "above",
            label: "每周额度",
            usedPercent: -10,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        let below = QuotaWindow(
            id: "below",
            label: "每周额度",
            usedPercent: 150,
            durationMinutes: 10_080,
            resetsAt: nil
        )

        let full = MenuBarPresentation.make(for: .fresh(snapshot(windows: [above])))
        let empty = MenuBarPresentation.make(for: .fresh(snapshot(windows: [below])))

        #expect(full.text == "100%")
        #expect(full.fillFraction == 1)
        #expect(full.band == .normal)
        #expect(empty.text == "0%")
        #expect(empty.fillFraction == 0)
        #expect(empty.band == .critical)
    }

    @Test
    func testLoadingMissingWeeklyStaleAndUnavailableStates() {
        let weekly = QuotaWindow(
            id: "weekly",
            label: "每周额度",
            usedPercent: 69,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        let loading = MenuBarPresentation.make(for: .loading)
        let missing = MenuBarPresentation.make(for: .fresh(snapshot(windows: [])))
        let stale = MenuBarPresentation.make(
            for: .stale(snapshot(windows: [weekly]), message: "offline")
        )
        let unavailable = MenuBarPresentation.make(
            for: .unavailable(message: "missing")
        )

        #expect(loading.text == "--")
        #expect(loading.fillFraction == 0)
        #expect(loading.band == nil)
        #expect(loading.accessibilityLabel == "每周剩余额度载入中")
        #expect(missing.text == "--")
        #expect(missing.fillFraction == 0)
        #expect(missing.band == nil)
        #expect(missing.accessibilityLabel == "每周剩余额度不可用")
        #expect(stale.text == "31% !")
        #expect(stale.fillFraction == 0.31)
        #expect(stale.band == .normal)
        #expect(stale.accessibilityLabel == "每周剩余额度 31%，数据可能已过期")
        #expect(unavailable.text == "不可用")
        #expect(unavailable.fillFraction == 0)
        #expect(unavailable.band == nil)
        #expect(unavailable.accessibilityLabel == "每周剩余额度不可用")
    }

    @Test
    func testMenuBarTextDoesNotIncludeResetCreditCount() {
        let weekly = QuotaWindow(
            id: "weekly",
            label: "每周额度",
            usedPercent: 69,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        let value = MenuBarPresentation.make(for: .fresh(snapshot(
            windows: [weekly],
            availableResetCount: 5
        )))

        #expect(value.text == "31%")
        #expect(!value.text.contains("·"))
    }

    private func snapshot(
        windows: [QuotaWindow],
        availableResetCount: Int = 0
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            windows: windows,
            availableResetCount: availableResetCount,
            resetCredits: [],
            fetchedAt: now
        )
    }
}
