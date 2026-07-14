import Foundation

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        100 - min(max(usedPercent, 0), 100)
    }
}

enum ResetCreditStatus: String, Codable, Equatable, Sendable {
    case available
    case redeeming
    case redeemed
    case unknown
}

struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let status: ResetCreditStatus
    let grantedAt: Date
    let expiresAt: Date?
    let title: String?
    let detail: String?
}

struct QuotaSnapshot: Codable, Equatable, Sendable {
    let windows: [QuotaWindow]
    let availableResetCount: Int
    let resetCredits: [ResetCredit]?
    let fetchedAt: Date

    var mostConstrainedRemainingPercent: Int? {
        windows.map(\.remainingPercent).min()
    }

    func isStale(at date: Date, threshold: TimeInterval = 1_800) -> Bool {
        date.timeIntervalSince(fetchedAt) >= threshold
    }
}

enum QuotaDisplayState: Equatable, Sendable {
    case loading
    case fresh(QuotaSnapshot)
    case stale(QuotaSnapshot, message: String)
    case unavailable(message: String)

    var snapshot: QuotaSnapshot? {
        switch self {
        case .fresh(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .unavailable: return nil
        }
    }
}
