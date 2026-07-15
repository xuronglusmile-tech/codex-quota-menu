import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaCacheTests {
    @Test
    func testRoundTripUsesEpochDatesAndPreservesStaleBoundary() async throws {
        try await Self.withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("quota-cache.json")
            let cache = FileQuotaCache(fileURL: fileURL)
            let fetchedAt = Date(timeIntervalSince1970: 1_000)
            let snapshot = Self.makeSnapshot(fetchedAt: fetchedAt)

            try await cache.save(snapshot)

            #expect(await cache.load() == snapshot)
            #expect(!snapshot.isStale(at: fetchedAt.addingTimeInterval(1_799)))
            #expect(snapshot.isStale(at: fetchedAt.addingTimeInterval(1_800)))

            let data = try Data(contentsOf: fileURL)
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect((object["fetchedAt"] as? NSNumber)?.doubleValue == 1_000)
        }
    }

    @Test
    func testCorruptCacheIsIgnored() async throws {
        try await Self.withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("quota-cache.json")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data("not-json".utf8).write(to: fileURL)

            #expect(await FileQuotaCache(fileURL: fileURL).load() == nil)
        }
    }

    @Test
    func testMissingCacheIsIgnoredWithoutCreatingAFile() async throws {
        try await Self.withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("quota-cache.json")

            #expect(await FileQuotaCache(fileURL: fileURL).load() == nil)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test
    func testLegacyCacheWithoutMonthlyUsageLoadsAsUnavailable() async throws {
        try await Self.withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("quota-cache.json")
            let legacyJSON = #"{"windows":[],"availableResetCount":0,"resetCredits":[],"fetchedAt":1000}"#
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(legacyJSON.utf8).write(to: fileURL)

            let snapshot = await FileQuotaCache(fileURL: fileURL).load()

            #expect(snapshot != nil)
            #expect(snapshot?.monthlyUsage == nil)
        }
    }

    @Test
    func testSaveCreatesMissingParentDirectory() async throws {
        try await Self.withTemporaryDirectory { rootDirectory in
            let directory = rootDirectory.appendingPathComponent("nested/cache")
            let fileURL = directory.appendingPathComponent("quota-cache.json")
            let snapshot = Self.makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 2_000))
            #expect(!FileManager.default.fileExists(atPath: directory.path))

            let cache = FileQuotaCache(fileURL: fileURL)
            try await cache.save(snapshot)

            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            #expect(await cache.load() == snapshot)
        }
    }

    @Test
    func testSaveAtomicallyOverwritesWithOneCompleteJSONDocument() async throws {
        try await Self.withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("quota-cache.json")
            let cache = FileQuotaCache(fileURL: fileURL)
            let first = Self.makeSnapshot(
                label: "obsolete-display-text-that-must-not-remain",
                fetchedAt: Date(timeIntervalSince1970: 3_000)
            )
            let replacement = QuotaSnapshot(
                windows: [],
                availableResetCount: 0,
                resetCredits: [],
                fetchedAt: Date(timeIntervalSince1970: 4_000)
            )

            try await cache.save(first)
            try await cache.save(replacement)

            let data = try Data(contentsOf: fileURL)
            let serialized = try #require(String(data: data, encoding: .utf8))
            _ = try JSONSerialization.jsonObject(with: data)
            #expect(await cache.load() == replacement)
            #expect(!serialized.contains("obsolete-display-text-that-must-not-remain"))

            let fileNames = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent)
                .sorted()
            #expect(fileNames == ["quota-cache.json"])
        }
    }

    @Test
    func testOnDiskShapeContainsOnlyDisplaySnapshotWithAnonymousCreditKey() async throws {
        try await Self.withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("quota-cache.json")
            let anonymousCreditKey = "c0052539940d448d4db1f62ef42f61e7a15b072337a0bedb04e3a869b96c85a5"
            let snapshot = QuotaSnapshot(
                windows: [
                    QuotaWindow(
                        id: "weekly",
                        label: "每周额度",
                        usedPercent: 53,
                        durationMinutes: 10_080,
                        resetsAt: Date(timeIntervalSince1970: 5_100)
                    )
                ],
                availableResetCount: 1,
                resetCredits: [
                    ResetCredit(
                        id: anonymousCreditKey,
                        status: .available,
                        grantedAt: Date(timeIntervalSince1970: 5_200),
                        expiresAt: Date(timeIntervalSince1970: 5_300),
                        title: "Full reset",
                        detail: "Available credit"
                    )
                ],
                monthlyUsage: MonthlyUsage(
                    monthStart: Date(timeIntervalSince1970: 4_900),
                    tokens: 5_000_000,
                    fetchedAt: Date(timeIntervalSince1970: 5_000)
                ),
                fetchedAt: Date(timeIntervalSince1970: 5_000)
            )

            try await FileQuotaCache(fileURL: fileURL).save(snapshot)

            let data = try Data(contentsOf: fileURL)
            let serialized = try #require(String(data: data, encoding: .utf8))
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(Set(object.keys) == [
                "windows", "availableResetCount", "resetCredits", "monthlyUsage", "fetchedAt"
            ])

            let monthlyUsage = try #require(object["monthlyUsage"] as? [String: Any])
            #expect(Set(monthlyUsage.keys) == ["monthStart", "tokens", "fetchedAt"])
            #expect((monthlyUsage["tokens"] as? NSNumber)?.int64Value == 5_000_000)

            let credits = try #require(object["resetCredits"] as? [[String: Any]])
            let credit = try #require(credits.first)
            #expect(Set(credit.keys) == [
                "id", "status", "grantedAt", "expiresAt", "title", "detail"
            ])
            #expect(credit["id"] as? String == anonymousCreditKey)
            #expect(!serialized.contains("raw-backend-credit-id"))
            #expect(!serialized.contains("\"token\""))
            #expect(!serialized.contains("accessToken"))
            #expect(!serialized.contains("accountToken"))
            #expect(!serialized.contains("credentials"))
            #expect(!serialized.contains("appServer"))
        }
    }

    @Test
    func testDefaultURLIsInsideNamedApplicationSupportDirectory() {
        let expected = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Codex Quota Menu", isDirectory: true)
            .appendingPathComponent("quota-cache.json")

        #expect(FileQuotaCache.defaultURL() == expected)
    }

    private static func makeSnapshot(
        label: String = "每周额度",
        fetchedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            windows: [
                QuotaWindow(
                    id: "weekly",
                    label: label,
                    usedPercent: 53,
                    durationMinutes: 10_080,
                    resetsAt: Date(timeIntervalSince1970: 1_100)
                )
            ],
            availableResetCount: 1,
            resetCredits: [
                ResetCredit(
                    id: "c0052539940d448d4db1f62ef42f61e7a15b072337a0bedb04e3a869b96c85a5",
                    status: .available,
                    grantedAt: Date(timeIntervalSince1970: 1_200),
                    expiresAt: Date(timeIntervalSince1970: 1_300),
                    title: "Full reset",
                    detail: "Available credit"
                )
            ],
            fetchedAt: fetchedAt
        )
    }

    private static func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
