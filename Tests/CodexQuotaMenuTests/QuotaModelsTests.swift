import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaModelsTests {
    private let now = Date(timeIntervalSince1970: 1_784_038_400)

    @Test
    func testRemainingPercentIsClamped() {
        #expect(QuotaWindow(id: "a", label: "A", usedPercent: -2, durationMinutes: 300, resetsAt: nil).remainingPercent == 100)
        #expect(QuotaWindow(id: "b", label: "B", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil).remainingPercent == 47)
        #expect(QuotaWindow(id: "c", label: "C", usedPercent: 140, durationMinutes: nil, resetsAt: nil).remainingPercent == 0)
    }

    @Test
    func testSnapshotUsesMostConstrainedWindow() {
        let snapshot = QuotaSnapshot(
            windows: [
                QuotaWindow(id: "five-hour", label: "5 小时额度", usedPercent: 9, durationMinutes: 300, resetsAt: nil),
                QuotaWindow(id: "weekly", label: "每周额度", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil)
            ],
            availableResetCount: 5,
            resetCredits: [],
            fetchedAt: now
        )
        #expect(snapshot.mostConstrainedRemainingPercent == 47)
    }

    @Test
    func testSnapshotStalenessIncludesThreshold() {
        let snapshot = QuotaSnapshot(
            windows: [],
            availableResetCount: 0,
            resetCredits: nil,
            fetchedAt: now
        )

        #expect(!snapshot.isStale(at: now.addingTimeInterval(1_799)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(1_800)))
    }

    @Test
    func testDisplayStateExposesFreshAndStaleSnapshots() {
        let snapshot = QuotaSnapshot(
            windows: [],
            availableResetCount: 0,
            resetCredits: nil,
            fetchedAt: now
        )

        #expect(QuotaDisplayState.fresh(snapshot).snapshot == snapshot)
        #expect(QuotaDisplayState.stale(snapshot, message: "offline").snapshot == snapshot)
        #expect(QuotaDisplayState.loading.snapshot == nil)
        #expect(QuotaDisplayState.unavailable(message: "missing").snapshot == nil)
    }

    @Test
    func testMenuTitleCoversFreshStaleAndUnavailableStates() {
        let snapshot = QuotaSnapshot(
            windows: [QuotaWindow(id: "weekly", label: "每周额度", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil)],
            availableResetCount: 5,
            resetCredits: [],
            fetchedAt: now
        )
        #expect(MenuBarPresentation.title(for: .fresh(snapshot)) == "47% · 5")
        #expect(MenuBarPresentation.title(for: .stale(snapshot, message: "offline")) == "47% · 5 !")
        #expect(MenuBarPresentation.title(for: .loading) == "— · —")
        #expect(MenuBarPresentation.title(for: .unavailable(message: "missing")) == "不可用")
    }
}
