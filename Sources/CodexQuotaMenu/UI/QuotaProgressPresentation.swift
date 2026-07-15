enum QuotaProgressBand: Equatable, Sendable {
    case normal
    case warning
    case critical
}

enum QuotaProgressPresentation {
    static func band(
        remainingPercent: Int,
        durationMinutes: Int?
    ) -> QuotaProgressBand? {
        guard durationMinutes == 10_080 else { return nil }
        if remainingPercent < 10 { return .critical }
        if remainingPercent < 20 { return .warning }
        return .normal
    }
}
