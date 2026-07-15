import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct LiveCodexSmokeTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_LIVE_CODEX_TESTS"] == "1",
            "Set RUN_LIVE_CODEX_TESTS=1 for the local account smoke test"
        )
    )
    func testRealReadReturnsAValidSnapshot() async throws {
        let reader = ProductionQuotaReader()
        let snapshot: QuotaSnapshot

        do {
            snapshot = try await reader.read()
        } catch {
            await reader.shutdown()
            throw error
        }

        #expect(!snapshot.windows.isEmpty)
        #expect(snapshot.availableResetCount >= 0)
        #expect(snapshot.windows.allSatisfy { (0...100).contains($0.remainingPercent) })

        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        for credit in snapshot.resetCredits ?? [] {
            #expect(credit.id.count == 64)
            #expect(credit.id.unicodeScalars.allSatisfy(lowercaseHex.contains))
        }

        await reader.shutdown()
    }
}
