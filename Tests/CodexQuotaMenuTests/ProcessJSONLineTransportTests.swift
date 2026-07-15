import Darwin
import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite(.serialized)
struct ProcessJSONLineTransportTests {
    @Test
    func testRoundTripsOneLineThroughCat() async throws {
        try await Self.withTransport { transport in
            try await transport.send("hello")
            #expect(try await transport.receive() == "hello")
        }
    }

    @Test
    func testRoundTripsMultipleFramesIncludingEmptyLine() async throws {
        try await Self.withTransport { transport in
            try await transport.send("")
            try await transport.send("first")
            try await transport.send("second")

            #expect(try await transport.receive() == "")
            #expect(try await transport.receive() == "first")
            #expect(try await transport.receive() == "second")
        }
    }

    @Test
    func testInvalidUTF8ThrowsSpecificError() async throws {
        try await Self.withTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["\\377\\n"]
        ) { transport in
            await Self.expectTransportError(.invalidUTF8) {
                _ = try await transport.receive()
            }
        }
    }

    @Test
    func testTrailingFragmentAtEOFIsDiscardedAndReceiveCloses() async throws {
        try await Self.withTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["partial"]
        ) { transport in
            await Self.expectTransportError(.closed) {
                _ = try await transport.receive()
            }
        }
    }

    @Test
    func testSendAndReceiveBeforeStartThrowNotStarted() async throws {
        try await Self.withTransport(startImmediately: false) { transport in
            await Self.expectTransportError(.notStarted) {
                try await transport.send("hello")
            }
            await Self.expectTransportError(.notStarted) {
                _ = try await transport.receive()
            }
        }
    }

    @Test
    func testCanRestartAfterIdempotentStop() async throws {
        try await Self.withTransport { transport in
            try await transport.start()
            try await transport.send("first")
            #expect(try await transport.receive() == "first")

            await transport.stop()
            await transport.stop()
            try await transport.start()

            try await transport.send("second")
            #expect(try await transport.receive() == "second")
        }
    }

    @Test
    func testConcurrentReceivesAreSerializedInCallOrder() async throws {
        try await Self.withTransport { transport in
            let first = Task { try await transport.receive() }
            try await Task<Never, Never>.sleep(for: .milliseconds(20))
            let second = Task { try await transport.receive() }
            let timeout = Task {
                do {
                    try await Task<Never, Never>.sleep(for: .seconds(1))
                } catch {
                    return
                }
                await transport.stop()
            }

            try await transport.send("first")
            try await transport.send("second")

            let firstResult = await first.result
            let secondResult = await second.result
            timeout.cancel()
            await timeout.value

            #expect(try firstResult.get() == "first")
            #expect(try secondResult.get() == "second")
        }
    }

    @Test
    func testStartDuringStopWaitsThenLaunchesNewGeneration() async throws {
        try await Self.withTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", Self.nonCooperativeScript]
        ) { transport in
            let oldPID = try Self.parsePID(try await transport.receive())
            let watchdog = Self.killAfterOneSecond(processID: oldPID)
            let clock = ContinuousClock()
            let startedAt = clock.now

            let stop = Task { await transport.stop() }
            try await Task<Never, Never>.sleep(for: .milliseconds(20))
            let restart = Task { try await transport.start() }

            await stop.value
            try await restart.value
            let elapsed = startedAt.duration(to: clock.now)
            watchdog.cancel()
            await watchdog.value

            let newPID = try Self.parsePID(try await transport.receive())
            #expect(newPID != oldPID)
            #expect(elapsed < .milliseconds(500))

            _ = kill(newPID, SIGKILL)
            await transport.stop()
            #expect(!Self.processExists(oldPID))
            #expect(!Self.processExists(newPID))
        }
    }

    @Test
    func testNonCooperativeProcessIsForceKilledAndReapedWithinBound() async throws {
        try await Self.withTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", Self.nonCooperativeScript]
        ) { transport in
            let processID = try Self.parsePID(try await transport.receive())
            let watchdog = Self.killAfterOneSecond(processID: processID)
            let clock = ContinuousClock()
            let startedAt = clock.now

            await transport.stop()

            let elapsed = startedAt.duration(to: clock.now)
            watchdog.cancel()
            await watchdog.value
            #expect(elapsed < .milliseconds(500))
            #expect(!Self.processExists(processID))
        }
    }

    @Test
    func testLaunchFailureLeavesTransportStoppedForRecovery() async throws {
        let executableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaMenuTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: executableURL) }

        try await Self.withTransport(
            executableURL: executableURL,
            startImmediately: false
        ) { transport in
            var launchFailed = false
            do {
                try await transport.start()
            } catch {
                launchFailed = true
            }
            #expect(launchFailed)

            await Self.expectTransportError(.notStarted) {
                try await transport.send("before-recovery")
            }

            try Data("#!/bin/sh\nexec /bin/cat\n".utf8).write(to: executableURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executableURL.path
            )

            try await transport.start()
            try await transport.send("recovered")
            #expect(try await transport.receive() == "recovered")
        }
    }

    @Test
    func testNoSigPipeConfigurationFailureReapsProcessAndCanRecover() async throws {
        let processIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaMenuTests-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDURL) }
        let configurator = FailingOnceNoSigPipeConfigurator(processIDURL: processIDURL)
        let transport = ProcessJSONLineTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > \"$1\"; exec /bin/cat",
                "codex-quota-menu-test",
                processIDURL.path
            ],
            configureNoSigPipe: { fileDescriptor in
                configurator.configure(fileDescriptor: fileDescriptor)
            }
        )

        do {
            try await transport.start()
            Issue.record("Expected F_SETNOSIGPIPE configuration to fail")
        } catch let error as ProcessJSONLineTransportError {
            #expect(error == .noSigPipeConfigurationFailed(errno: EIO))
            #expect(error.localizedDescription.contains("F_SETNOSIGPIPE"))
        } catch {
            Issue.record("Expected ProcessJSONLineTransportError, got \(error)")
        }

        let failedProcessID = try Self.parsePID(
            String(contentsOf: processIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(!Self.processExists(failedProcessID))
        await Self.expectTransportError(.notStarted) {
            try await transport.send("before-recovery")
        }

        do {
            try await transport.start()
            try await transport.send("recovered")
            #expect(try await transport.receive() == "recovered")
            #expect(configurator.callCount == 2)
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
    }

    @Test
    func testWriteFailurePropagatesAfterChildClosesInput() async throws {
        try await Self.withTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["ready\\n"]
        ) { transport in
            let line = try await transport.receive()
            #expect(line == "ready")
            await Self.expectTransportError(.closed) {
                _ = try await transport.receive()
            }

            var writeFailed = false
            do {
                try await transport.send("too-late")
            } catch {
                writeFailed = true
            }
            #expect(writeFailed)
        }
    }

    @Test
    func testStopReapsProcessAndCatChild() async throws {
        try await Self.withTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "cat & child=$!; echo \"$$ $child\"; wait \"$child\"; sleep 1"
            ]
        ) { transport in
            let components = try await transport.receive().split(separator: " ")
            #expect(components.count == 2)
            let shellPID = try #require(components.first.flatMap { pid_t($0) })
            let catPID = try #require(components.last.flatMap { pid_t($0) })

            await transport.stop()

            #expect(!Self.processExists(shellPID))
            #expect(!Self.processExists(catPID))
        }
    }

    private static let nonCooperativeScript =
        "$SIG{TERM} = 'IGNORE'; $| = 1; print \"$$\\n\"; select undef, undef, undef, 2;"

    private static func withTransport<Result>(
        executableURL: URL = URL(fileURLWithPath: "/bin/cat"),
        arguments: [String] = [],
        startImmediately: Bool = true,
        operation: (ProcessJSONLineTransport) async throws -> Result
    ) async throws -> Result {
        let transport = ProcessJSONLineTransport(
            executableURL: executableURL,
            arguments: arguments
        )

        do {
            if startImmediately {
                try await transport.start()
            }
            let result = try await operation(transport)
            await transport.stop()
            return result
        } catch {
            await transport.stop()
            throw error
        }
    }

    private static func expectTransportError(
        _ expected: JSONLineTransportError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected transport error: \(expected)")
        } catch let error as JSONLineTransportError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }

    private static func parsePID(_ line: String) throws -> pid_t {
        try #require(pid_t(line))
    }

    private static func killAfterOneSecond(processID: pid_t) -> Task<Void, Never> {
        Task {
            do {
                try await Task<Never, Never>.sleep(for: .seconds(1))
            } catch {
                return
            }
            _ = kill(processID, SIGKILL)
        }
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }
}

private final class FailingOnceNoSigPipeConfigurator: @unchecked Sendable {
    private let lock = NSLock()
    private let processIDURL: URL
    private var storedCallCount = 0

    init(processIDURL: URL) {
        self.processIDURL = processIDURL
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func configure(fileDescriptor: Int32) -> Int32 {
        let attempt = lock.withLock {
            storedCallCount += 1
            return storedCallCount
        }
        guard attempt == 1 else {
            return fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: processIDURL.path), Date() < deadline {
            usleep(1_000)
        }
        errno = EIO
        return -1
    }
}
