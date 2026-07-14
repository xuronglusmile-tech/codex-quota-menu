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

    @Test
    func testProductionReaderUsesOnlyAppServerStdioAndReusesOneClient() async throws {
        let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let now = Date(timeIntervalSince1970: 1_784_038_400)
        let locator = RecordingCodexLocator(executable: executable)
        let factory = RecordingProductionClientFactory(response: Self.response)
        let reader = ProductionQuotaReader(
            locator: locator,
            makeClient: { url, arguments in factory.make(url: url, arguments: arguments) },
            now: { now }
        )

        let first = try await reader.read()
        let second = try await reader.read()

        #expect(first.fetchedAt == now)
        #expect(second.availableResetCount == 2)
        #expect(locator.locateCount == 1)
        #expect(factory.invocations == [
            .init(executableURL: executable, arguments: ["app-server", "--stdio"])
        ])
        #expect(await factory.clients.first?.readCount == 2)
    }

    @Test
    func testProductionReaderShutdownIsIdempotentAndNextReadCreatesFreshClient() async throws {
        let executable = URL(fileURLWithPath: "/bundled/codex")
        let locator = RecordingCodexLocator(executable: executable)
        let factory = RecordingProductionClientFactory(response: Self.response)
        let reader = ProductionQuotaReader(
            locator: locator,
            makeClient: { url, arguments in factory.make(url: url, arguments: arguments) }
        )

        _ = try await reader.read()
        let firstClient = try #require(factory.clients.first)
        await reader.shutdown()
        await reader.shutdown()

        #expect(await firstClient.stopCount == 1)
        _ = try await reader.read()
        #expect(locator.locateCount == 2)
        #expect(factory.clients.count == 2)
        #expect(factory.invocations.allSatisfy { $0.arguments == ["app-server", "--stdio"] })
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

private struct ProductionClientInvocation: Equatable {
    let executableURL: URL
    let arguments: [String]
}

private final class RecordingCodexLocator: CodexExecutableLocating, @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private var storedLocateCount = 0

    init(executable: URL) {
        self.executable = executable
    }

    var locateCount: Int {
        lock.withLock { storedLocateCount }
    }

    func locate() throws -> URL {
        lock.withLock { storedLocateCount += 1 }
        return executable
    }
}

private final class RecordingProductionClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let response: RateLimitsReadResponse
    private var storedInvocations: [ProductionClientInvocation] = []
    private var storedClients: [RecordingProductionClient] = []

    init(response: RateLimitsReadResponse) {
        self.response = response
    }

    var invocations: [ProductionClientInvocation] {
        lock.withLock { storedInvocations }
    }

    var clients: [RecordingProductionClient] {
        lock.withLock { storedClients }
    }

    func make(url: URL, arguments: [String]) -> any ProductionRateLimitsClient {
        let client = RecordingProductionClient(response: response)
        lock.withLock {
            storedInvocations.append(
                ProductionClientInvocation(executableURL: url, arguments: arguments)
            )
            storedClients.append(client)
        }
        return client
    }
}

private actor RecordingProductionClient: ProductionRateLimitsClient {
    private let response: RateLimitsReadResponse
    private(set) var readCount = 0
    private(set) var stopCount = 0

    init(response: RateLimitsReadResponse) {
        self.response = response
    }

    func readRateLimits() async throws -> RateLimitsReadResponse {
        readCount += 1
        return response
    }

    func stop() async {
        stopCount += 1
    }
}

private struct StubRateLimitsReader: RateLimitsReading {
    let response: RateLimitsReadResponse

    func readRateLimits() async throws -> RateLimitsReadResponse {
        response
    }
}
