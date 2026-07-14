enum MenuBarPresentation {
    static func title(for state: QuotaDisplayState) -> String {
        switch state {
        case .loading:
            return "— · —"
        case .unavailable:
            return "不可用"
        case .fresh(let snapshot):
            return title(snapshot: snapshot, suffix: "")
        case .stale(let snapshot, _):
            return title(snapshot: snapshot, suffix: " !")
        }
    }

    private static func title(snapshot: QuotaSnapshot, suffix: String) -> String {
        let percent = snapshot.mostConstrainedRemainingPercent.map { "\($0)%" } ?? "—"
        return "\(percent) · \(snapshot.availableResetCount)\(suffix)"
    }
}
