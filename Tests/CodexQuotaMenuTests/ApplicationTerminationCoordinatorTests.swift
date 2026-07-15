import AppKit
import Testing
@testable import CodexQuotaMenu

@Suite(.serialized)
@MainActor
struct ApplicationTerminationCoordinatorTests {
    @Test
    func testCoalescesCleanupAndRepliesExactlyOnceBeforeCompleting() async {
        let cleanup = ControlledTerminationCleanup()
        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            cleanup: { await cleanup.run() },
            reply: { replies.record($0) }
        )

        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(replies.values.isEmpty)
        await cleanup.waitUntilStarted()

        #expect(cleanup.callCount == 1)
        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(cleanup.callCount == 1)
        #expect(replies.values.isEmpty)

        cleanup.finish()
        await replies.waitUntilCount(1)

        #expect(cleanup.callCount == 1)
        #expect(replies.values == [true])
        #expect(coordinator.requestTermination() == .terminateNow)
        #expect(replies.values == [true])
    }

    @Test
    func testUnconfiguredCoordinatorTerminatesImmediatelyWithoutReply() {
        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            reply: { replies.record($0) }
        )

        #expect(coordinator.requestTermination() == .terminateNow)
        #expect(coordinator.requestTermination() == .terminateNow)
        #expect(replies.values.isEmpty)
    }
}

@MainActor
private final class ControlledTerminationCleanup {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func run() async {
        callCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class TerminationReplyRecorder {
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
        let ready = waiters.filter { $0.0 <= values.count }
        waiters.removeAll { $0.0 <= values.count }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}
