import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct CodexAppServerClientTests {
    @Test
    func testInitializesThenReadsRateLimitsUsingOnlyWhitelistedMethodsAndExactParameters() async throws {
        let transport = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 5))
        let client = CodexAppServerClient(makeTransport: { transport }, timeoutSeconds: 1)

        let result = try await client.readRateLimits()

        #expect(result.rateLimitResetCredits?.availableCount == 5)
        let objects = try await transport.sentLines.map(Self.decodeObject)
        #expect(objects.count == 3)
        #expect(objects.compactMap { $0["method"] as? String } == [
            "initialize",
            "initialized",
            "account/rateLimits/read"
        ])
        #expect(Set(AppServerMethod.allCases.map(\.rawValue)) == Set(objects.compactMap { $0["method"] as? String }))

        #expect(objects[0]["id"] as? Int == 0)
        let initializeParams = try #require(objects[0]["params"] as? [String: Any])
        let clientInfo = try #require(initializeParams["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "codex_quota_menu")
        #expect(clientInfo["title"] as? String == "Codex Quota Menu")
        #expect(clientInfo["version"] as? String == "0.1.0")

        #expect(objects[1]["id"] == nil)
        #expect((objects[1]["params"] as? [String: Any])?.isEmpty == true)
        #expect(objects[2]["id"] as? Int == 1)
        #expect(objects[2]["params"] is NSNull)
    }

    @Test
    func testSkipsInterleavedNotificationsAndResponsesWithOtherIDs() async throws {
        let transport = ScriptedJSONLineTransport(lines: [
            #"{"method":"account/rateLimits/updated","params":{}}"#,
            #"{"id":"initialize-other","result":{}}"#,
            #"{"id":0.5,"result":{}}"#,
            #"{"id":99,"result":{}}"#,
            #"{"id":0,"result":{"userAgent":"test"}}"#,
            #"{"method":"account/rateLimits/updated","params":{}}"#,
            #"{"id":"read-other","result":{}}"#,
            #"{"id":1.5,"result":{}}"#,
            #"{"id":0,"result":{"userAgent":"late"}}"#,
            Self.rateLimitsResponse(resetCount: 7)
        ])
        let client = CodexAppServerClient(makeTransport: { transport }, timeoutSeconds: 1)

        let result = try await client.readRateLimits()

        #expect(result.rateLimitResetCredits?.availableCount == 7)
        #expect(await transport.sentLines.count == 3)
    }

    @Test
    func testServerErrorPreservesCodeAndMessageAfterExactlyOneRetry() async {
        let first = ScriptedJSONLineTransport(lines: Self.serverErrorLines(code: -32_001, message: "first"))
        let second = ScriptedJSONLineTransport(lines: Self.serverErrorLines(code: -32_002, message: "second"))
        let queue = TransportQueue([first, second])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected server error")
        } catch let error as AppServerClientError {
            guard case .server(let code, let message) = error else {
                Issue.record("Expected server error, got \(error)")
                return
            }
            #expect(code == -32_002)
            #expect(message == "second")
        } catch {
            Issue.record("Expected AppServerClientError.server, got \(error)")
        }

        #expect(queue.makeCount == 2)
    }

    @Test
    func testMalformedMatchingResponseFailsAfterExactlyOneRetry() async {
        let first = ScriptedJSONLineTransport(lines: ["not-json"])
        let second = ScriptedJSONLineTransport(lines: [#"{"id":0,"result":null}"#])
        let queue = TransportQueue([first, second])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected malformed response")
        } catch let error as AppServerClientError {
            guard case .malformedResponse = error else {
                Issue.record("Expected malformed response, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppServerClientError.malformedResponse, got \(error)")
        }

        #expect(queue.makeCount == 2)
    }

    @Test
    func testClosedTransportErrorIsReturnedAfterExactlyOneRetry() async {
        let first = ClosedJSONLineTransport()
        let second = ClosedJSONLineTransport()
        let queue = TransportQueue([first, second])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected closed transport")
        } catch let error as JSONLineTransportError {
            #expect(error == .closed)
        } catch {
            Issue.record("Expected JSONLineTransportError.closed, got \(error)")
        }

        #expect(queue.makeCount == 2)
        #expect(await first.stopCount > 0)
        #expect(await second.stopCount > 0)
    }

    @Test
    func testRestartsTransportExactlyOnceThenReturnsSuccessfulResponse() async throws {
        let failed = ClosedJSONLineTransport()
        let successful = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 5))
        let queue = TransportQueue([failed, successful])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        let result = try await client.readRateLimits()

        #expect(result.rateLimitResetCredits?.availableCount == 5)
        #expect(queue.makeCount == 2)
        #expect(await failed.stopCount > 0)
    }

    @Test
    func testTimeoutCompletesWhenReceiveIgnoresCancellationAndStopsBothAttempts() async {
        let first = CancellationIgnoringTransport()
        let second = CancellationIgnoringTransport()
        let queue = TransportQueue([first, second])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 0.02)
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected timeout")
        } catch let error as AppServerClientError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppServerClientError.timeout, got \(error)")
        }

        #expect(startedAt.duration(to: clock.now) < .milliseconds(500))
        #expect(queue.makeCount == 2)
        #expect(await first.didStop)
        #expect(await second.didStop)
        #expect(await first.receiveCount == 1)
        #expect(await second.receiveCount == 1)
    }

    @Test
    func testInvalidTimeoutIntervalBecomesAnImmediateBoundedTimeout() async {
        let first = CancellationIgnoringTransport()
        let second = CancellationIgnoringTransport()
        let queue = TransportQueue([first, second])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: .nan)
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await client.readRateLimits()
            Issue.record("Expected timeout")
        } catch let error as AppServerClientError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppServerClientError.timeout, got \(error)")
        }

        #expect(startedAt.duration(to: clock.now) < .milliseconds(500))
        #expect(queue.makeCount == 2)
        #expect(await first.didStop)
        #expect(await second.didStop)
    }

    @Test
    func testConcurrentReadsShareOneHandshakeAndOneRead() async throws {
        let transport = ControllableJSONLineTransport()
        let queue = TransportQueue([transport])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        let first = Task { try await client.readRateLimits() }
        await transport.waitUntilReceiveCount(1)
        let second = Task { try await client.readRateLimits() }
        await Task<Never, Never>.yield()
        #expect(queue.makeCount == 1)

        await transport.enqueue(#"{"id":0,"result":{"userAgent":"test"}}"#)
        await transport.waitUntilReceiveCount(2)
        await transport.enqueue(Self.rateLimitsResponse(resetCount: 9))

        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.rateLimitResetCredits?.availableCount == 9)
        #expect(secondResult.rateLimitResetCredits?.availableCount == 9)
        #expect(queue.makeCount == 1)
        #expect(await transport.sentLines.compactMap(Self.decodeMethod) == [
            "initialize",
            "initialized",
            "account/rateLimits/read"
        ])
    }

    @Test
    func testStopResetsTransportAndNextReadPerformsFreshHandshake() async throws {
        let first = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 1))
        let second = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 2))
        let queue = TransportQueue([first, second])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        let firstResult = try await client.readRateLimits()
        await client.stop()
        let secondResult = try await client.readRateLimits()

        #expect(firstResult.rateLimitResetCredits?.availableCount == 1)
        #expect(secondResult.rateLimitResetCredits?.availableCount == 2)
        #expect(queue.makeCount == 2)
        #expect(await first.stopCount > 0)
        #expect(await first.sentLines.compactMap(Self.decodeMethod) == [
            "initialize",
            "initialized",
            "account/rateLimits/read"
        ])
        #expect(await second.sentLines.compactMap(Self.decodeMethod) == [
            "initialize",
            "initialized",
            "account/rateLimits/read"
        ])
    }

    @Test
    func testStopDuringInitializePreventsAReadFromResurrectingTransport() async {
        let stopping = StopSuspendingTransport(blocksStart: true, lines: [])
        let resurrected = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 2))
        let queue = TransportQueue([stopping, resurrected])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        let initializing = Task { try await client.readRateLimits() }
        await stopping.waitUntilStartEntered()
        let stop = Task { await client.stop() }
        await stopping.waitUntilStopStarted()

        Self.expectCancellation(await initializing.result)
        let readDuringStop = await Task { try await client.readRateLimits() }.result

        Self.expectCancellation(readDuringStop)
        #expect(queue.makeCount == 1)
        await stopping.releaseStop()
        await stop.value
    }

    @Test
    func testStopDuringReadPreventsAReadFromResurrectingTransport() async {
        let stopping = StopSuspendingTransport(
            blocksStart: false,
            lines: [#"{"id":0,"result":{"userAgent":"test"}}"#]
        )
        let resurrected = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 2))
        let queue = TransportQueue([stopping, resurrected])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)

        let reading = Task { try await client.readRateLimits() }
        await stopping.waitUntilReceiveCount(2)
        let stop = Task { await client.stop() }
        await stopping.waitUntilStopStarted()

        Self.expectCancellation(await reading.result)
        let readDuringStop = await Task { try await client.readRateLimits() }.result

        Self.expectCancellation(readDuringStop)
        #expect(queue.makeCount == 1)
        await stopping.releaseStop()
        await stop.value
    }

    @Test
    func testReadEnteringDuringStopFailsWithoutLaunchingTransport() async throws {
        let stopping = StopSuspendingTransport(
            blocksStart: false,
            lines: Self.successLines(resetCount: 1)
        )
        let resurrected = ScriptedJSONLineTransport(lines: Self.successLines(resetCount: 2))
        let queue = TransportQueue([stopping, resurrected])
        let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)
        _ = try await client.readRateLimits()

        let stop = Task { await client.stop() }
        await stopping.waitUntilStopStarted()
        let readDuringStop = await Task { try await client.readRateLimits() }.result

        Self.expectCancellation(readDuringStop)
        #expect(queue.makeCount == 1)
        await stopping.releaseStop()
        await stop.value
    }

    @Test
    func testTimeoutThatAwakensAfterResponseLosesWithoutStoppingHealthyTransport() async throws {
        let transport = StopAwareScriptedTransport(lines: [
            #"{"id":0,"result":{"userAgent":"test"}}"#,
            Self.rateLimitsResponse(resetCount: 4),
            Self.rateLimitsResponse(resetCount: 5)
        ])
        let queue = TransportQueue([transport])
        let sleeper = CancellationReturningSleeper()
        let client = CodexAppServerClient(
            makeTransport: { queue.next() },
            timeoutSeconds: 1,
            timeoutSleep: { duration in
                await sleeper.waitUntilCancelled(after: duration)
            }
        )

        let first = try await client.readRateLimits()
        let second = try await client.readRateLimits()

        #expect(first.rateLimitResetCredits?.availableCount == 4)
        #expect(second.rateLimitResetCredits?.availableCount == 5)
        #expect(queue.makeCount == 1)
        #expect(await transport.stopCount == 0)
        #expect(await sleeper.returnCount == 3)
        #expect(await transport.sentLines.compactMap(Self.decodeMethod) == [
            "initialize",
            "initialized",
            "account/rateLimits/read",
            "account/rateLimits/read"
        ])
    }

    private static func successLines(resetCount: Int) -> [String] {
        [
            #"{"id":0,"result":{"userAgent":"test"}}"#,
            rateLimitsResponse(resetCount: resetCount)
        ]
    }

    private static func serverErrorLines(code: Int, message: String) -> [String] {
        [
            #"{"id":0,"result":{"userAgent":"test"}}"#,
            #"{"id":1,"error":{"code":\#(code),"message":"\#(message)"}}"#
        ]
    }

    private static func rateLimitsResponse(resetCount: Int) -> String {
        #"{"id":1,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":53,"windowDurationMins":10080,"resetsAt":1784503858},"secondary":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":\#(resetCount),"credits":[]}}}"#
    }

    private static func decodeObject(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private static func decodeMethod(_ line: String) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        return object["method"] as? String
    }

    private static func expectCancellation(
        _ result: Result<RateLimitsReadResponse, any Error>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch result {
        case .success:
            Issue.record("Expected cancellation", sourceLocation: sourceLocation)
        case .failure(let error):
            #expect(error is CancellationError, sourceLocation: sourceLocation)
        }
    }
}

private actor ScriptedJSONLineTransport: JSONLineTransport {
    private var lines: [String]
    private(set) var sentLines: [String] = []
    private(set) var stopCount = 0

    init(lines: [String]) {
        self.lines = lines
    }

    func start() async throws {}

    func send(_ line: String) async throws {
        sentLines.append(line)
    }

    func receive() async throws -> String {
        guard !lines.isEmpty else { throw JSONLineTransportError.closed }
        return lines.removeFirst()
    }

    func stop() async {
        stopCount += 1
    }
}

private actor ClosedJSONLineTransport: JSONLineTransport {
    private(set) var stopCount = 0

    func start() async throws {}
    func send(_ line: String) async throws {}
    func receive() async throws -> String { throw JSONLineTransportError.closed }
    func stop() async { stopCount += 1 }
}

private actor CancellationIgnoringTransport: JSONLineTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var receiveCount = 0
    private(set) var didStop = false

    func start() async throws {}
    func send(_ line: String) async throws {}

    func receive() async throws -> String {
        receiveCount += 1
        await withCheckedContinuation { continuation in
            if didStop {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        throw JSONLineTransportError.closed
    }

    func stop() async {
        didStop = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ControllableJSONLineTransport: JSONLineTransport {
    private struct CountWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var lines: [String] = []
    private var receivers: [CheckedContinuation<String, any Error>] = []
    private var countWaiters: [CountWaiter] = []
    private var receiveCount = 0
    private(set) var sentLines: [String] = []

    func start() async throws {}

    func send(_ line: String) async throws {
        sentLines.append(line)
    }

    func receive() async throws -> String {
        receiveCount += 1
        resumeSatisfiedCountWaiters()
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receivers.append(continuation)
        }
    }

    func stop() async {
        let pending = receivers
        receivers.removeAll()
        pending.forEach { $0.resume(throwing: JSONLineTransportError.closed) }
    }

    func enqueue(_ line: String) {
        if receivers.isEmpty {
            lines.append(line)
        } else {
            receivers.removeFirst().resume(returning: line)
        }
    }

    func waitUntilReceiveCount(_ target: Int) async {
        guard receiveCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    private func resumeSatisfiedCountWaiters() {
        let satisfied = countWaiters.filter { $0.target <= receiveCount }
        countWaiters.removeAll { $0.target <= receiveCount }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor StopSuspendingTransport: JSONLineTransport {
    private struct CountWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let blocksStart: Bool
    private var lines: [String]
    private var receivers: [CheckedContinuation<String, any Error>] = []
    private var receiveCount = 0
    private var receiveWaiters: [CountWaiter] = []
    private var startEntered = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopStarted = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopReleased = false
    private var stopCount = 0
    private var didStop = false

    init(blocksStart: Bool, lines: [String]) {
        self.blocksStart = blocksStart
        self.lines = lines
    }

    func start() async throws {
        startEntered = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if blocksStart && !didStop {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        guard !didStop else { throw JSONLineTransportError.closed }
    }

    func send(_ line: String) async throws {
        guard !didStop else { throw JSONLineTransportError.closed }
    }

    func receive() async throws -> String {
        receiveCount += 1
        resumeSatisfiedReceiveWaiters()
        guard !didStop else { throw JSONLineTransportError.closed }
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receivers.append(continuation)
        }
    }

    func stop() async {
        stopCount += 1
        guard stopCount == 1 else { return }

        didStop = true
        startContinuation?.resume()
        startContinuation = nil
        let pendingReceivers = receivers
        receivers.removeAll()
        pendingReceivers.forEach { $0.resume(throwing: JSONLineTransportError.closed) }

        stopStarted = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !stopReleased else { return }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func waitUntilStartEntered() async {
        guard !startEntered else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReceiveCount(_ target: Int) async {
        guard receiveCount < target else { return }
        await withCheckedContinuation { continuation in
            receiveWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    func waitUntilStopStarted() async {
        guard !stopStarted else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func releaseStop() {
        stopReleased = true
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func resumeSatisfiedReceiveWaiters() {
        let satisfied = receiveWaiters.filter { $0.target <= receiveCount }
        receiveWaiters.removeAll { $0.target <= receiveCount }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor StopAwareScriptedTransport: JSONLineTransport {
    private var lines: [String]
    private var stopped = false
    private(set) var sentLines: [String] = []
    private(set) var stopCount = 0

    init(lines: [String]) {
        self.lines = lines
    }

    func start() async throws {
        guard !stopped else { throw JSONLineTransportError.closed }
    }

    func send(_ line: String) async throws {
        guard !stopped else { throw JSONLineTransportError.closed }
        sentLines.append(line)
    }

    func receive() async throws -> String {
        guard !stopped, !lines.isEmpty else { throw JSONLineTransportError.closed }
        return lines.removeFirst()
    }

    func stop() async {
        stopCount += 1
        stopped = true
    }
}

private actor CancellationReturningSleeper {
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelled: Set<UUID> = []
    private(set) var returnCount = 0

    func waitUntilCancelled(after duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelled.remove(id) != nil {
                    returnCount += 1
                    continuation.resume()
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        if let continuation = continuations.removeValue(forKey: id) {
            returnCount += 1
            continuation.resume()
        } else {
            cancelled.insert(id)
        }
    }
}

private final class TransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any JSONLineTransport]
    private var count = 0

    init(_ transports: [any JSONLineTransport]) {
        self.transports = transports
    }

    var makeCount: Int {
        lock.withLock { count }
    }

    func next() -> any JSONLineTransport {
        lock.withLock {
            count += 1
            return transports.removeFirst()
        }
    }
}
