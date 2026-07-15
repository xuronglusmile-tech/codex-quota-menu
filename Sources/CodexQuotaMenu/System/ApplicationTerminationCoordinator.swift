import AppKit

@MainActor
final class ApplicationTerminationCoordinator {
    typealias Cleanup = @MainActor () async -> Void
    typealias Reply = @MainActor (Bool) -> Void

    private enum State {
        case idle
        case stopping
        case finished
    }

    private let cleanup: Cleanup?
    private let reply: Reply
    private var state = State.idle
    private var cleanupTask: Task<Void, Never>?

    init(
        cleanup: Cleanup? = nil,
        reply: @escaping Reply
    ) {
        self.cleanup = cleanup
        self.reply = reply
    }

    func requestTermination() -> NSApplication.TerminateReply {
        switch state {
        case .finished:
            return .terminateNow
        case .stopping:
            return .terminateLater
        case .idle:
            guard let cleanup else {
                state = .finished
                return .terminateNow
            }

            state = .stopping
            cleanupTask = Task { @MainActor in
                await cleanup()
                finishCleanup()
            }
            return .terminateLater
        }
    }

    private func finishCleanup() {
        guard state == .stopping else { return }
        state = .finished
        cleanupTask = nil
        reply(true)
    }
}
