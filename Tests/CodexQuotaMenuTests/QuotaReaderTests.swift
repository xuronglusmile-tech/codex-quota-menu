import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaReaderTests {
    @Test
    func testReaderUsesInjectedTimeForFetchedAt() async throws {
        let fixed = Date(timeIntervalSince1970: 1_784_038_400)
        let reader = LiveQuotaReader(
            client: StubCodexAccountReader(response: .init(
                rateLimits: Self.response,
                usage: nil
            )),
            now: { fixed }
        )

        let snapshot = try await reader.read()

        #expect(snapshot.fetchedAt == fixed)
        #expect(snapshot.availableResetCount == 2)
    }

    @Test
    func testReaderAttachesCurrentMonthUsage() async throws {
        let fixed = Date(timeIntervalSince1970: 1_783_958_400)
        let reader = LiveQuotaReader(
            client: StubCodexAccountReader(response: .init(
                rateLimits: Self.response,
                usage: AccountUsageReadResponse(
                    dailyUsageBuckets: [
                        .init(startDate: "2026-07-01", tokens: 2_000_000),
                        .init(startDate: "2026-07-16", tokens: 3_000_000)
                    ],
                    summary: Self.emptyUsageSummary
                )
            )),
            now: { fixed },
            calendar: Self.shanghaiCalendar
        )

        let snapshot = try await reader.read()

        #expect(snapshot.monthlyUsage?.tokens == 5_000_000)
        #expect(snapshot.windows.isEmpty == false)
        #expect(snapshot.availableResetCount == 2)
    }

    @Test
    func testNilOrInvalidUsageDoesNotRemoveRateLimits() async throws {
        let nilUsage = LiveQuotaReader(
            client: StubCodexAccountReader(response: .init(
                rateLimits: Self.response,
                usage: nil
            )),
            now: { .distantPast }
        )
        let invalidUsage = LiveQuotaReader(
            client: StubCodexAccountReader(response: .init(
                rateLimits: Self.response,
                usage: .init(
                    dailyUsageBuckets: [.init(startDate: "bad", tokens: 1)],
                    summary: Self.emptyUsageSummary
                )
            )),
            now: { .distantPast }
        )
        let nilBuckets = LiveQuotaReader(
            client: StubCodexAccountReader(response: .init(
                rateLimits: Self.response,
                usage: .init(
                    dailyUsageBuckets: nil,
                    summary: Self.emptyUsageSummary
                )
            )),
            now: { .distantPast }
        )

        #expect(try await nilUsage.read().monthlyUsage == nil)
        #expect(try await invalidUsage.read().monthlyUsage == nil)
        #expect(try await nilBuckets.read().monthlyUsage == nil)
        #expect(try await nilUsage.read().windows.isEmpty == false)
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
            client: StubCodexAccountReader(response: .init(
                rateLimits: response,
                usage: nil
            )),
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

    @Test
    func testReadEnteringDuringProductionShutdownIsRejectedWithoutCreatingClient() async throws {
        let firstClient = ControllableProductionClient(
            response: Self.response,
            suspendStop: true
        )
        let unexpectedClient = ControllableProductionClient(response: Self.response)
        let factory = QueuedProductionClientFactory(
            clients: [firstClient, unexpectedClient]
        )
        let reader = ProductionQuotaReader(
            locator: RecordingCodexLocator(executable: URL(fileURLWithPath: "/bundled/codex")),
            makeClient: { url, arguments in factory.make(url: url, arguments: arguments) }
        )
        _ = try await reader.read()

        let shutdown = Task { await reader.shutdown() }
        await firstClient.waitUntilStopStarts()

        do {
            _ = try await reader.read()
            Issue.record("Expected read during shutdown to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(factory.invocations.count == 1)
        #expect(await unexpectedClient.readCount == 0)

        await firstClient.resumeStop()
        await shutdown.value
    }

    @Test
    func testConcurrentProductionShutdownsAwaitOneClientCleanup() async throws {
        let client = ControllableProductionClient(
            response: Self.response,
            suspendStop: true
        )
        let factory = QueuedProductionClientFactory(clients: [client])
        let reader = ProductionQuotaReader(
            locator: RecordingCodexLocator(executable: URL(fileURLWithPath: "/bundled/codex")),
            makeClient: { url, arguments in factory.make(url: url, arguments: arguments) }
        )
        _ = try await reader.read()

        let firstCompletion = ReaderCompletionProbe()
        let secondCompletion = ReaderCompletionProbe()
        let first = Task {
            await reader.shutdown()
            await firstCompletion.markFinished(beforeStopRelease: !(await client.stopWasReleased))
        }
        await client.waitUntilStopStarts()
        let second = Task {
            await secondCompletion.markStarted()
            await reader.shutdown()
            await secondCompletion.markFinished(beforeStopRelease: !(await client.stopWasReleased))
        }
        await secondCompletion.waitUntilStarted()
        for _ in 0..<10 {
            await Task<Never, Never>.yield()
        }

        await client.resumeStop()
        await first.value
        await second.value

        #expect(!(await firstCompletion.finishedBeforeStopRelease))
        #expect(!(await secondCompletion.finishedBeforeStopRelease))
        #expect(await client.stopCount == 1)
        #expect(factory.invocations.count == 1)
    }

    @Test
    func testInFlightProductionReadInvalidatedByShutdownCannotReturnSnapshot() async {
        let client = ControllableProductionClient(
            response: Self.response,
            suspendRead: true
        )
        let factory = QueuedProductionClientFactory(clients: [client])
        let reader = ProductionQuotaReader(
            locator: RecordingCodexLocator(executable: URL(fileURLWithPath: "/bundled/codex")),
            makeClient: { url, arguments in factory.make(url: url, arguments: arguments) }
        )

        let read = Task { try await reader.read() }
        await client.waitUntilReadStarts()
        await reader.shutdown()
        await client.resumeRead()

        do {
            _ = try await read.value
            Issue.record("Expected invalidated in-flight read to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(factory.invocations.count == 1)
        #expect(await client.stopCount == 1)
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

    private static let emptyUsageSummary = WireAccountUsageSummary(
        currentStreakDays: nil,
        lifetimeTokens: nil,
        longestRunningTurnSec: nil,
        longestStreakDays: nil,
        peakDailyTokens: nil
    )

    private static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
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

    func make(url: URL, arguments: [String]) -> any ProductionAccountClient {
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

private actor RecordingProductionClient: ProductionAccountClient {
    private let response: RateLimitsReadResponse
    private(set) var readCount = 0
    private(set) var stopCount = 0

    init(response: RateLimitsReadResponse) {
        self.response = response
    }

    func readAccountSnapshot() async throws -> CodexAccountReadResponse {
        readCount += 1
        return CodexAccountReadResponse(rateLimits: response, usage: nil)
    }

    func stop() async {
        stopCount += 1
    }
}

private final class QueuedProductionClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any ProductionAccountClient]
    private var storedInvocations: [ProductionClientInvocation] = []

    init(clients: [any ProductionAccountClient]) {
        self.clients = clients
    }

    var invocations: [ProductionClientInvocation] {
        lock.withLock { storedInvocations }
    }

    func make(url: URL, arguments: [String]) -> any ProductionAccountClient {
        lock.withLock {
            storedInvocations.append(
                ProductionClientInvocation(executableURL: url, arguments: arguments)
            )
            precondition(!clients.isEmpty, "Unexpected production client creation")
            return clients.removeFirst()
        }
    }
}

private actor ControllableProductionClient: ProductionAccountClient {
    private let response: RateLimitsReadResponse
    private let suspendRead: Bool
    private let suspendStop: Bool
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    private(set) var stopCount = 0
    private(set) var stopWasReleased = false

    init(
        response: RateLimitsReadResponse,
        suspendRead: Bool = false,
        suspendStop: Bool = false
    ) {
        self.response = response
        self.suspendRead = suspendRead
        self.suspendStop = suspendStop
    }

    func readAccountSnapshot() async throws -> CodexAccountReadResponse {
        readCount += 1
        let waiters = readStartWaiters
        readStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendRead {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return CodexAccountReadResponse(rateLimits: response, usage: nil)
    }

    func stop() async {
        stopCount += 1
        let waiters = stopStartWaiters
        stopStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendStop {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        stopWasReleased = true
    }

    func waitUntilReadStarts() async {
        guard readCount == 0 else { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }

    func waitUntilStopStarts() async {
        guard stopCount == 0 else { return }
        await withCheckedContinuation { continuation in
            stopStartWaiters.append(continuation)
        }
    }

    func resumeRead() {
        let continuation = readContinuation
        readContinuation = nil
        continuation?.resume()
    }

    func resumeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
}

private actor ReaderCompletionProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var finishedBeforeStopRelease = false

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markFinished(beforeStopRelease: Bool) {
        finishedBeforeStopRelease = beforeStopRelease
    }
}

private struct StubCodexAccountReader: CodexAccountReading {
    let response: CodexAccountReadResponse

    func readAccountSnapshot() async throws -> CodexAccountReadResponse {
        response
    }
}
