import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaReaderTests {
    @Test
    func testReaderUsesInjectedTimeForFetchedAt() async throws {
        let fixed = Date(timeIntervalSince1970: 1_784_038_400)
        let reader = LiveQuotaReader(
            client: StubRateLimitsReader(response: Self.response),
            now: { fixed }
        )

        let snapshot = try await reader.read()

        #expect(snapshot.fetchedAt == fixed)
        #expect(snapshot.availableResetCount == 2)
    }

    @Test
    func testReaderPropagatesMapperErrorForResponseWithoutQuotaWindows() async {
        let response = RateLimitsReadResponse(
            rateLimits: WireRateLimitSnapshot(
                limitId: "codex",
                limitName: nil,
                primary: nil,
                secondary: nil
            ),
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil
        )
        let reader = LiveQuotaReader(
            client: StubRateLimitsReader(response: response),
            now: { .distantPast }
        )

        do {
            _ = try await reader.read()
            Issue.record("Expected no-quota-windows mapper error")
        } catch let error as QuotaMappingError {
            guard case .noQuotaWindows = error else {
                Issue.record("Expected noQuotaWindows, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected QuotaMappingError.noQuotaWindows, got \(error)")
        }
    }

    private static let response = RateLimitsReadResponse(
        rateLimits: WireRateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: WireRateLimitWindow(
                usedPercent: 10,
                windowDurationMins: 300,
                resetsAt: nil
            ),
            secondary: nil
        ),
        rateLimitsByLimitId: nil,
        rateLimitResetCredits: WireResetCreditsSummary(availableCount: 2, credits: [])
    )
}

private struct StubRateLimitsReader: RateLimitsReading {
    let response: RateLimitsReadResponse

    func readRateLimits() async throws -> RateLimitsReadResponse {
        response
    }
}
