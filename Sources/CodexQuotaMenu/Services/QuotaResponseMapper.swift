import CryptoKit
import Foundation

enum QuotaMappingError: LocalizedError {
    case noQuotaWindows

    var errorDescription: String? { "Codex 返回的数据中没有可识别的额度窗口。" }
}

enum QuotaResponseMapper {
    static func map(_ response: RateLimitsReadResponse, fetchedAt: Date) throws -> QuotaSnapshot {
        let buckets: [(keyedID: String, snapshot: WireRateLimitSnapshot)]
        if let keyed = response.rateLimitsByLimitId, !keyed.isEmpty {
            buckets = keyed.keys.sorted().compactMap { keyedID in
                keyed[keyedID].map { (keyedID, $0) }
            }
        } else {
            buckets = [("codex", response.rateLimits)]
        }

        let windows = buckets.flatMap { entry in
            let (keyedID, bucket) = entry
            return [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { entry -> QuotaWindow? in
                let (slot, optionalWindow) = entry
                guard let window = optionalWindow else { return nil }
                return QuotaWindow(
                    id: "\(bucket.limitId ?? keyedID)-\(slot)",
                    label: label(for: window.windowDurationMins, fallback: bucket.limitName),
                    usedPercent: window.usedPercent,
                    durationMinutes: window.windowDurationMins,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }
        guard !windows.isEmpty else { throw QuotaMappingError.noQuotaWindows }

        let details = response.rateLimitResetCredits?.credits?.compactMap { wire -> ResetCredit? in
            let status = ResetCreditStatus(rawValue: wire.status) ?? .unknown
            guard status == .available else { return nil }
            let expiration = wire.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return ResetCredit(
                id: stableKey(backendID: wire.id, expiresAt: expiration),
                status: status,
                grantedAt: Date(timeIntervalSince1970: TimeInterval(wire.grantedAt)),
                expiresAt: expiration,
                title: wire.title,
                detail: wire.description
            )
        }.sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.id < rhs.id
            }
        }

        return QuotaSnapshot(
            windows: windows,
            availableResetCount: max(response.rateLimitResetCredits?.availableCount ?? 0, 0),
            resetCredits: response.rateLimitResetCredits?.credits == nil ? nil : details,
            fetchedAt: fetchedAt
        )
    }

    private static func label(for minutes: Int?, fallback: String?) -> String {
        switch minutes {
        case 300: return "5 小时额度"
        case 10_080: return "每周额度"
        default:
            if let fallback, !fallback.isEmpty { return fallback }
            return "Codex 额度"
        }
    }

    private static func stableKey(backendID: String, expiresAt: Date?) -> String {
        let seconds = expiresAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "never"
        let digest = SHA256.hash(data: Data("\(backendID)\u{0}\(seconds)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
