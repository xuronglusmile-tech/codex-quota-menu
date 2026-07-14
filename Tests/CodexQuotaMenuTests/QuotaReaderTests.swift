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

private final class QueuedProductionClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any ProductionRateLimitsClient]
    private var storedInvocations: [ProductionClientInvocation] = []

    init(clients: [any ProductionRateLimitsClient]) {
        self.clients = clients
    }

    var invocations: [ProductionClientInvocation] {
        lock.withLock { storedInvocations }
    }

    func make(url: URL, arguments: [String]) -> any ProductionRateLimitsClient {
        lock.withLock {
            storedInvocations.append(
                ProductionClientInvocation(executableURL: url, arguments: arguments)
            )
            precondition(!clients.isEmpty, "Unexpected production client creation")
            return clients.removeFirst()
        }
    }
}

private actor ControllableProductionClient: ProductionRateLimitsClient {
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

    func readRateLimits() async throws -> RateLimitsReadResponse {
        readCount += 1
        let waiters = readStartWaiters
        readStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendRead {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return response
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

private struct StubRateLimitsReader: RateLimitsReading {
    let response: RateLimitsReadResponse

    func readRateLimits() async throws -> RateLimitsReadResponse {
        response
    }
}
