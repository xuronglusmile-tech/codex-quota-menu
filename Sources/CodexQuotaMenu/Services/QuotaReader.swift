import Foundation

protocol QuotaReading: Sendable {
    func read() async throws -> QuotaSnapshot
}

struct LiveQuotaReader: QuotaReading {
    let client: any RateLimitsReading
    let now: @Sendable () -> Date

    init(
        client: any RateLimitsReading,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.now = now
    }

    func read() async throws -> QuotaSnapshot {
        let response = try await client.readRateLimits()
        return try QuotaResponseMapper.map(response, fetchedAt: now())
    }
}
