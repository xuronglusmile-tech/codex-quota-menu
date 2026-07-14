import Foundation

struct RateLimitsReadResponse: Decodable, Sendable {
    let rateLimits: WireRateLimitSnapshot
    let rateLimitsByLimitId: [String: WireRateLimitSnapshot]?
    let rateLimitResetCredits: WireResetCreditsSummary?
}

struct WireRateLimitSnapshot: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: WireRateLimitWindow?
    let secondary: WireRateLimitWindow?
}

struct WireRateLimitWindow: Decodable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

struct WireResetCreditsSummary: Decodable, Sendable {
    let availableCount: Int
    let credits: [WireResetCredit]?
}

struct WireResetCredit: Decodable, Sendable {
    let id: String
    let status: String
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?
}
