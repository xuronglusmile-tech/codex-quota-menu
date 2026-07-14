import Darwin
import Foundation

actor ProcessJSONLineTransport: JSONLineTransport {
    private enum LifecycleState {
        case stopped
        case running(generation: UInt64)
        case stopping(generation: UInt64, task: Task<Void, Never>?)
    }

    private struct ReceiveWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct StopResources {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let readerTask: Task<Void, Never>
        let terminationEvents: AsyncStream<Void>
    }

    private static let terminationGrace: Duration = .milliseconds(100)
    private static let terminationPollInterval: Duration = .milliseconds(5)

    private let executableURL: URL
    private let arguments: [String]
    private var lifecycle: LifecycleState = .stopped
    private var generationCounter: UInt64 = 0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var iterator: AsyncThrowingStream<String, Error>.Iterator?
    private var readerTask: Task<Void, Never>?
    private var terminationEvents: AsyncStream<Void>?
    private var buffer = Data()
    private var receiveOwnerGeneration: UInt64?
    private var receiveWaiters: [ReceiveWaiter] = []

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func start() async throws {
        while true {
            switch lifecycle {
            case .stopped:
                try launch()
                return
            case .running:
                return
            case .stopping(_, let task):
                if let task {
                    await task.value
                } else {
                    await Task<Never, Never>.yield()
                }
            }
        }
    }

    func send(_ line: String) async throws {
        guard case .running = lifecycle, let input else {
            throw JSONLineTransportError.notStarted
        }
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    func receive() async throws -> String {
        guard case .running(let generation) = lifecycle else {
            throw JSONLineTransportError.notStarted
        }
        guard await acquireReceiveTurn(for: generation) else {
            throw JSONLineTransportError.closed
        }
        guard isRunning(generation), var iterator else {
            releaseReceiveTurn(for: generation)
            throw JSONLineTransportError.closed
        }

        self.iterator = nil
        let line: String?
        do {
            line = try await iterator.next()
        } catch {
            if isRunning(generation) {
                self.iterator = iterator
            }
            releaseReceiveTurn(for: generation)
            throw error
        }

        let generationIsCurrent = isRunning(generation)
        if generationIsCurrent {
            self.iterator = iterator
        }
        releaseReceiveTurn(for: generation)

        guard generationIsCurrent, let line else {
            throw JSONLineTransportError.closed
        }
        return line
    }

    func stop() async {
        while true {
            switch lifecycle {
            case .stopped:
                return
            case .running(let generation):
                guard let task = beginStop(generation: generation) else {
                    return
                }
                await task.value
                return
            case .stopping(_, let task):
                if let task {
                    await task.value
                    return
                }
                await Task<Never, Never>.yield()
            }
        }
    }

    private func launch() throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let terminationPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        process.terminationHandler = { _ in
            terminationPair.continuation.yield(())
            terminationPair.continuation.finish()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationPair.continuation.finish()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            throw error
        }

        _ = fcntl(
            inputPipe.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        )

        generationCounter &+= 1
        let generation = generationCounter
        let output = outputPipe.fileHandleForReading
        let streamPair = AsyncThrowingStream<String, Error>.makeStream()

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = output
        self.iterator = streamPair.stream.makeAsyncIterator()
        self.terminationEvents = terminationPair.stream
        self.buffer.removeAll(keepingCapacity: true)
        self.lifecycle = .running(generation: generation)
        self.readerTask = Task { [weak self] in
            guard let self else {
                streamPair.continuation.finish()
                return
            }

            do {
                for try await byte in output.bytes {
                    try Task.checkCancellation()
                    guard await self.consume(
                        byte,
                        generation: generation,
                        continuation: streamPair.continuation
                    ) else {
                        return
                    }
                }
                await self.finishReading(
                    generation: generation,
                    error: nil,
                    continuation: streamPair.continuation
                )
            } catch {
                await self.finishReading(
                    generation: generation,
                    error: Task.isCancelled ? nil : error,
                    continuation: streamPair.continuation
                )
            }
        }
    }

    private func beginStop(generation: UInt64) -> Task<Void, Never>? {
        guard
            case .running(let activeGeneration) = lifecycle,
            activeGeneration == generation,
            let process,
            let input,
            let output,
            let readerTask,
            let terminationEvents
        else {
            lifecycle = .stopped
            invalidateReceives()
            clearProcessState()
            return nil
        }

        lifecycle = .stopping(generation: generation, task: nil)
        invalidateReceives()
        let resources = StopResources(
            process: process,
            input: input,
            output: output,
            readerTask: readerTask,
            terminationEvents: terminationEvents
        )
        clearProcessState()

        let task = Task { [weak self] in
            await Self.cleanUp(resources)
            await self?.finishStop(generation: generation)
        }
        lifecycle = .stopping(generation: generation, task: task)
        return task
    }

    private static func cleanUp(_ resources: StopResources) async {
        try? resources.input.close()
        resources.readerTask.cancel()
        try? resources.output.close()

        if resources.process.isRunning {
            _ = kill(resources.process.processIdentifier, SIGTERM)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: terminationGrace)
        while resources.process.isRunning && clock.now < deadline {
            try? await Task<Never, Never>.sleep(for: terminationPollInterval)
        }

        if resources.process.isRunning {
            _ = kill(resources.process.processIdentifier, SIGKILL)
        }

        var terminationIterator = resources.terminationEvents.makeAsyncIterator()
        _ = await terminationIterator.next()
        await resources.readerTask.value
        resources.process.terminationHandler = nil
    }

    private func finishStop(generation: UInt64) {
        guard
            case .stopping(let activeGeneration, _) = lifecycle,
            activeGeneration == generation
        else { return }
        buffer.removeAll(keepingCapacity: true)
        lifecycle = .stopped
    }

    private func clearProcessState() {
        process = nil
        input = nil
        output = nil
        iterator = nil
        readerTask = nil
        terminationEvents = nil
    }

    private func acquireReceiveTurn(for generation: UInt64) async -> Bool {
        guard isRunning(generation) else { return false }
        guard receiveOwnerGeneration != nil else {
            receiveOwnerGeneration = generation
            return true
        }

        return await withCheckedContinuation { continuation in
            guard isRunning(generation) else {
                continuation.resume(returning: false)
                return
            }
            receiveWaiters.append(ReceiveWaiter(
                generation: generation,
                continuation: continuation
            ))
        }
    }

    private func releaseReceiveTurn(for generation: UInt64) {
        guard receiveOwnerGeneration == generation else { return }

        while !receiveWaiters.isEmpty {
            let waiter = receiveWaiters.removeFirst()
            guard waiter.generation == generation, isRunning(generation) else {
                waiter.continuation.resume(returning: false)
                continue
            }
            waiter.continuation.resume(returning: true)
            return
        }
        receiveOwnerGeneration = nil
    }

    private func invalidateReceives() {
        receiveOwnerGeneration = nil
        let waiters = receiveWaiters
        receiveWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
    }

    private func isRunning(_ generation: UInt64) -> Bool {
        guard case .running(let activeGeneration) = lifecycle else { return false }
        return activeGeneration == generation
    }

    private func consume(
        _ byte: UInt8,
        generation: UInt64,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> Bool {
        guard isRunning(generation) else {
            continuation.finish()
            return false
        }
        guard byte == 0x0A else {
            buffer.append(byte)
            return true
        }

        let lineData = buffer
        buffer.removeAll(keepingCapacity: true)
        guard let line = String(data: lineData, encoding: .utf8) else {
            continuation.finish(throwing: JSONLineTransportError.invalidUTF8)
            return false
        }
        continuation.yield(line)
        return true
    }

    private func finishReading(
        generation: UInt64,
        error: Error?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        if isRunning(generation) {
            buffer.removeAll(keepingCapacity: true)
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
