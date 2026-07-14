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

    @Test
    func testKeyedBucketsWithoutEmbeddedLimitIDsUseUniqueDictionaryKeys() throws {
        let response = Self.makeResponse(
            keyed: [
                "alpha": Self.makeSnapshot(
                    primary: Self.makeWindow(usedPercent: 10, durationMinutes: 300)
                ),
                "beta": Self.makeSnapshot(
                    primary: Self.makeWindow(usedPercent: 20, durationMinutes: 300)
                )
            ]
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)

        #expect(snapshot.windows.map(\.id) == ["alpha-primary", "beta-primary"])
        #expect(Set(snapshot.windows.map(\.id)).count == 2)
    }

    @Test
    func testNegativeAvailableCountIsClampedToZero() throws {
        let response = Self.makeResponse(
            resetCredits: WireResetCreditsSummary(availableCount: -3, credits: nil)
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)

        #expect(snapshot.availableResetCount == 0)
        #expect(snapshot.resetCredits == nil)
    }

    @Test
    func testNoWindowsThrowsNoQuotaWindowsError() {
        let response = Self.makeResponse(
            legacy: Self.makeSnapshot(primary: nil, secondary: nil)
        )

        #expect(throws: QuotaMappingError.self) {
            try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        }
    }

    @Test
    func testOnlyAvailableCreditDetailsAreMapped() throws {
        let response = Self.makeResponse(
            resetCredits: WireResetCreditsSummary(
                availableCount: 4,
                credits: [
                    Self.makeCredit(id: "redeemed", status: "redeemed"),
                    Self.makeCredit(id: "redeeming", status: "redeeming"),
                    Self.makeCredit(id: "future", status: "futureStatus"),
                    Self.makeCredit(id: "available", status: "available", title: "Available")
                ]
            )
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        let credits = try #require(snapshot.resetCredits)

        #expect(snapshot.availableResetCount == 4)
        #expect(credits.count == 1)
        #expect(credits.first?.status == .available)
        #expect(credits.first?.title == "Available")
    }

    @Test
    func testFallsBackToLegacyBucketWhenKeyedBucketsAreEmpty() throws {
        let response = Self.makeResponse(
            legacy: Self.makeSnapshot(
                limitId: "legacy-only",
                limitName: "Fallback quota",
                primary: Self.makeWindow(usedPercent: 25, durationMinutes: 60)
            ),
            keyed: [:]
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)

        #expect(snapshot.windows.map(\.id) == ["legacy-only-primary"])
        #expect(snapshot.windows.map(\.label) == ["Fallback quota"])
    }

    @Test
    func testCreditDetailsAreSortedByExpirationWithNoExpirationLast() throws {
        let response = Self.makeResponse(
            resetCredits: WireResetCreditsSummary(
                availableCount: 4,
                credits: [
                    Self.makeCredit(id: "later", expiresAt: 300),
                    Self.makeCredit(id: "never-a", expiresAt: nil),
                    Self.makeCredit(id: "earlier", expiresAt: 100),
                    Self.makeCredit(id: "never-b", expiresAt: nil)
                ]
            )
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        let credits = try #require(snapshot.resetCredits)
        let expectedExpirations: [Date?] = [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 300),
            nil,
            nil
        ]

        #expect(credits.map(\.expiresAt) == expectedExpirations)
        let noExpirationIDs = credits.suffix(2).map(\.id)
        #expect(noExpirationIDs == noExpirationIDs.sorted())
    }

    @Test
    func testMapsWindowResetAndCreditGrantEpochs() throws {
        let response = Self.makeResponse(
            legacy: Self.makeSnapshot(
                primary: Self.makeWindow(usedPercent: 10, durationMinutes: 300, resetsAt: 1_111)
            ),
            resetCredits: WireResetCreditsSummary(
                availableCount: 1,
                credits: [Self.makeCredit(id: "epoch", grantedAt: 2_222)]
            )
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        let credit = try #require(snapshot.resetCredits?.first)

        #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_111))
        #expect(credit.grantedAt == Date(timeIntervalSince1970: 2_222))
    }

    @Test
    func testCreditIdentityIsStableLowercaseSHA256Hex() throws {
        let response = Self.makeResponse(
            resetCredits: WireResetCreditsSummary(
                availableCount: 1,
                credits: [Self.makeCredit(id: "stable-id", expiresAt: 1_784_335_339)]
            )
        )

        let first = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        let second = try QuotaResponseMapper.map(response, fetchedAt: .distantFuture)
        let firstID = try #require(first.resetCredits?.first?.id)
        let secondID = try #require(second.resetCredits?.first?.id)

        #expect(firstID == secondID)
        #expect(firstID == "c0052539940d448d4db1f62ef42f61e7a15b072337a0bedb04e3a869b96c85a5")
        #expect(firstID.count == 64)
        #expect(firstID.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        })
    }

    @Test
    func testEmptyCreditDetailsRemainKnownEmpty() throws {
        let response = Self.makeResponse(
            resetCredits: WireResetCreditsSummary(availableCount: 0, credits: [])
        )

        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)

        #expect(snapshot.resetCredits != nil)
        #expect(snapshot.resetCredits?.isEmpty == true)
    }

    private static func makeResponse(
        legacy: WireRateLimitSnapshot = makeSnapshot(
            limitId: "legacy",
            primary: makeWindow(usedPercent: 0, durationMinutes: 300)
        ),
        keyed: [String: WireRateLimitSnapshot]? = nil,
        resetCredits: WireResetCreditsSummary? = nil
    ) -> RateLimitsReadResponse {
        RateLimitsReadResponse(
            rateLimits: legacy,
            rateLimitsByLimitId: keyed,
            rateLimitResetCredits: resetCredits
        )
    }

    private static func makeSnapshot(
        limitId: String? = nil,
        limitName: String? = nil,
        primary: WireRateLimitWindow?,
        secondary: WireRateLimitWindow? = nil
    ) -> WireRateLimitSnapshot {
        WireRateLimitSnapshot(
            limitId: limitId,
            limitName: limitName,
            primary: primary,
            secondary: secondary
        )
    }

    private static func makeWindow(
        usedPercent: Int,
        durationMinutes: Int?,
        resetsAt: Int64? = nil
    ) -> WireRateLimitWindow {
        WireRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: durationMinutes,
            resetsAt: resetsAt
        )
    }

    private static func makeCredit(
        id: String,
        status: String = "available",
        grantedAt: Int64 = 0,
        expiresAt: Int64? = nil,
        title: String? = nil
    ) -> WireResetCredit {
        WireResetCredit(
            id: id,
            status: status,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            title: title,
            description: nil
        )
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
