struct MenuBarPresentation: Equatable, Sendable {
    let text: String
    let fillFraction: Double
    let band: QuotaProgressBand?
    let accessibilityLabel: String

    private static let weeklyDurationMinutes = 10_080

    static func make(for state: QuotaDisplayState) -> MenuBarPresentation {
        switch state {
        case .loading:
            return unavailable(
                text: "--",
                accessibilityLabel: "每周剩余额度载入中"
            )
        case .unavailable:
            return unavailable(
                text: "不可用",
                accessibilityLabel: "每周剩余额度不可用"
            )
        case .fresh(let snapshot):
            return make(snapshot: snapshot, isStale: false)
        case .stale(let snapshot, _):
            return make(snapshot: snapshot, isStale: true)
        }
    }

    private static func make(
        snapshot: QuotaSnapshot,
        isStale: Bool
    ) -> MenuBarPresentation {
        guard let weekly = snapshot.windows.first(where: {
            $0.durationMinutes == weeklyDurationMinutes
        }) else {
            return unavailable(
                text: "--",
                accessibilityLabel: "每周剩余额度不可用"
            )
        }

        let remaining = weekly.remainingPercent
        let suffix = isStale ? " !" : ""
        let accessibilitySuffix = isStale ? "，数据可能已过期" : ""

        return MenuBarPresentation(
            text: "\(remaining)%\(suffix)",
            fillFraction: Double(remaining) / 100,
            band: QuotaProgressPresentation.band(
                remainingPercent: remaining,
                durationMinutes: weekly.durationMinutes
            ),
            accessibilityLabel: "每周剩余额度 \(remaining)%\(accessibilitySuffix)"
        )
    }

    private static func unavailable(
        text: String,
        accessibilityLabel: String
    ) -> MenuBarPresentation {
        MenuBarPresentation(
            text: text,
            fillFraction: 0,
            band: nil,
            accessibilityLabel: accessibilityLabel
        )
    }
}
