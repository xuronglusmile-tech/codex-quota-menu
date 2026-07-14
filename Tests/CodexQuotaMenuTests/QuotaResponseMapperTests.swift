import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaResponseMapperTests {
    @Test
    func testMapsWindowsCountAndCreditExpirationWithoutPersistingBackendID() throws {
        let data = Data(Self.responseJSON.utf8)
        let response = try JSONDecoder().decode(RateLimitsReadResponse.self, from: data)
        let fetchedAt = Date(timeIntervalSince1970: 1_784_038_400)
        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: fetchedAt)

        #expect(snapshot.windows.map(\.label) == ["每周额度"])
        #expect(snapshot.windows.first?.remainingPercent == 47)
        #expect(snapshot.availableResetCount == 5)
        #expect(snapshot.resetCredits?.count == 1)
        let credit = try #require(snapshot.resetCredits?.first)
        #expect(credit.expiresAt == Date(timeIntervalSince1970: 1_784_335_339))
        #expect(credit.id != "backend-secret-id")
        #expect(credit.id.count == 64)
    }

    @Test
    func testNullCreditDetailsKeepsAvailableCount() throws {
        let data = Data(Self.responseJSON.replacingOccurrences(
            of: #""credits":[{"id":"backend-secret-id","resetType":"codexRateLimits","status":"available","grantedAt":1781743339,"expiresAt":1784335339,"title":"Full reset","description":"Granted"}]"#,
            with: #""credits":null"#
        ).utf8)
        let response = try JSONDecoder().decode(RateLimitsReadResponse.self, from: data)
        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        #expect(snapshot.availableResetCount == 5)
        #expect(snapshot.resetCredits == nil)
    }

    @Test
    func testMapsPrimaryAndSecondaryWindowsWithoutDuplicatingLegacyBucket() throws {
        let response = RateLimitsReadResponse(
            rateLimits: WireRateLimitSnapshot(
                limitId: "legacy",
                limitName: nil,
                primary: WireRateLimitWindow(usedPercent: 99, windowDurationMins: 300, resetsAt: nil),
                secondary: nil
            ),
            rateLimitsByLimitId: [
                "codex": WireRateLimitSnapshot(
                    limitId: "codex",
                    limitName: nil,
                    primary: WireRateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
                    secondary: WireRateLimitWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: nil)
                )
            ],
            rateLimitResetCredits: WireResetCreditsSummary(availableCount: 0, credits: [])
        )
        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        #expect(snapshot.windows.map(\.label) == ["5 小时额度", "每周额度"])
        #expect(snapshot.mostConstrainedRemainingPercent == 60)
    }

    private static let responseJSON = #"""
    {
      "rateLimits": {
        "limitId": "codex",
        "primary": {"usedPercent": 53, "windowDurationMins": 10080, "resetsAt": 1784503858},
        "secondary": null
      },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex",
          "primary": {"usedPercent": 53, "windowDurationMins": 10080, "resetsAt": 1784503858},
          "secondary": null,
          "unknownFutureField": true
        }
      },
      "rateLimitResetCredits": {
        "availableCount": 5,
        "credits":[{"id":"backend-secret-id","resetType":"codexRateLimits","status":"available","grantedAt":1781743339,"expiresAt":1784335339,"title":"Full reset","description":"Granted"}]
      }
    }
    """#
}
