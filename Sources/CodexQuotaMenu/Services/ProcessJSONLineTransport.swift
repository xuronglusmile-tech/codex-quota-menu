import Foundation

actor ProcessJSONLineTransport: JSONLineTransport {
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var iterator: AsyncThrowingStream<String, Error>.Iterator?
    private var readerTask: Task<Void, Never>?
    private var buffer = Data()

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func start() async throws {
        guard process == nil else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let output = outputPipe.fileHandleForReading
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = output
        self.iterator = stream.makeAsyncIterator()
        self.buffer.removeAll(keepingCapacity: true)
        self.readerTask = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }

            do {
                for try await byte in output.bytes {
                    try Task.checkCancellation()
                    guard await self.consume(byte, continuation: continuation) else {
                        return
                    }
                }
                await self.resetBuffer()
                continuation.finish()
            } catch {
                await self.resetBuffer()
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func send(_ line: String) async throws {
        guard let input else { throw JSONLineTransportError.notStarted }
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    func receive() async throws -> String {
        guard var iterator else { throw JSONLineTransportError.notStarted }
        guard let line = try await iterator.next() else {
            throw JSONLineTransportError.closed
        }
        self.iterator = iterator
        return line
    }

    func stop() async {
        let input = self.input
        let output = self.output
        let readerTask = self.readerTask
        let process = self.process

        self.input = nil
        self.output = nil
        iterator = nil

        try? input?.close()
        readerTask?.cancel()
        try? output?.close()
        if process?.isRunning == true {
            process?.terminate()
        }

        await readerTask?.value
        process?.waitUntilExit()

        self.process = nil
        self.readerTask = nil
        buffer.removeAll(keepingCapacity: true)
    }

    private func consume(
        _ byte: UInt8,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> Bool {
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

    private func resetBuffer() {
        buffer.removeAll(keepingCapacity: true)
    }
}
