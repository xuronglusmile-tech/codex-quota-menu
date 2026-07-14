import Foundation

enum AppServerMethod: String, CaseIterable, Sendable {
    case initialize
    case initialized
    case rateLimitsRead = "account/rateLimits/read"
}

protocol RateLimitsReading: Sendable {
    func readRateLimits() async throws -> RateLimitsReadResponse
}

enum AppServerClientError: LocalizedError, Equatable {
    case timeout
    case malformedResponse
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "读取 Codex 额度超时。"
        case .malformedResponse:
            return "Codex 返回了无法识别的数据。"
        case .server(_, let message):
            return message
        }
    }
}

private struct MessageHeader: Decodable {
    let id: JSONRPCID?
}

private enum JSONRPCID: Decodable {
    case integer(Int64)
    case unsignedInteger(UInt64)
    case string(String)
    case otherNumber

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if (try? container.decode(Double.self)) != nil {
            self = .otherNumber
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "JSON-RPC id must be a string or number."
                )
            )
        }
    }

    func matches(_ expected: Int) -> Bool {
        switch self {
        case .integer(let value):
            return value == Int64(expected)
        case .unsignedInteger(let value):
            return expected >= 0 && value == UInt64(expected)
        case .string, .otherNumber:
            return false
        }
    }
}

private struct RPCError: Decodable {
    let code: Int
    let message: String
}

private struct RPCResponse<Result: Decodable>: Decodable {
    let id: Int
    let result: Result?
    let error: RPCError?
}

private struct IgnoredResult: Decodable, Sendable {}

private enum ResponseRaceCompletion<Value: Sendable>: Sendable {
    case success(Value)
    case failure(any Error)
    case loser
}

private actor ResponseOutcomeGate {
    private enum Winner {
        case pending
        case response
        case timeout
    }

    private var winner = Winner.pending

    func claimResponse() -> Bool {
        claim(.response)
    }

    func claimTimeout() -> Bool {
        claim(.timeout)
    }

    private func claim(_ contender: Winner) -> Bool {
        guard case .pending = winner else { return false }
        winner = contender
        return true
    }
}

actor CodexAppServerClient: RateLimitsReading {
    private enum LifecycleState {
        case active(generation: UInt64)
        case stopping(generation: UInt64, task: Task<Void, Never>?)
    }

    private struct OwnedTransport {
        let generation: UInt64
        let value: any JSONLineTransport
    }

    private struct InFlightRead {
        let id: UInt64
        let generation: UInt64
        let task: Task<RateLimitsReadResponse, any Error>
    }

    private let makeTransport: @Sendable () -> any JSONLineTransport
    private let timeoutSeconds: TimeInterval
    private let timeoutSleep: @Sendable (Duration) async throws -> Void
    private var lifecycle: LifecycleState = .active(generation: 0)
    private var transport: OwnedTransport?
    private var inFlightRead: InFlightRead?
    private var nextReadID: UInt64 = 0

    init(
        makeTransport: @escaping @Sendable () -> any JSONLineTransport,
        timeoutSeconds: TimeInterval = 10,
        timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task<Never, Never>.sleep(for: $0)
        }
    ) {
        self.makeTransport = makeTransport
        self.timeoutSeconds = timeoutSeconds.isFinite && timeoutSeconds > 0 ? timeoutSeconds : 0
        self.timeoutSleep = timeoutSleep
    }

    func readRateLimits() async throws -> RateLimitsReadResponse {
        guard case .active(let generation) = lifecycle else {
            throw CancellationError()
        }
        if let inFlightRead {
            guard inFlightRead.generation == generation else {
                throw CancellationError()
            }
            return try await inFlightRead.task.value
        }

        nextReadID &+= 1
        let readID = nextReadID
        let task = Task { try await self.readWithOneRetry(generation: generation) }
        inFlightRead = InFlightRead(id: readID, generation: generation, task: task)

        do {
            let response = try await task.value
            clearInFlightRead(id: readID, generation: generation)
            return response
        } catch {
            clearInFlightRead(id: readID, generation: generation)
            throw error
        }
    }

    func stop() async {
        while true {
            switch lifecycle {
            case .active(let generation):
                lifecycle = .stopping(generation: generation, task: nil)
                let read = inFlightRead
                read?.task.cancel()
                let ownedTransport = takeTransport(generation: generation)
                let task = Task { [weak self] in
                    await ownedTransport?.stop()
                    if let read {
                        _ = await read.task.result
                    }
                    await self?.finishStop(
                        generation: generation,
                        readID: read?.id
                    )
                }
                lifecycle = .stopping(generation: generation, task: task)
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

    private func readWithOneRetry(generation: UInt64) async throws -> RateLimitsReadResponse {
        for attempt in 0..<2 {
            try ensureActive(generation: generation)
            do {
                return try await readOnce(generation: generation)
            } catch {
                await resetTransport(generation: generation)
                try ensureActive(generation: generation)
                if attempt == 1 {
                    throw error
                }
            }
        }
        throw AppServerClientError.malformedResponse
    }

    private func readOnce(generation: UInt64) async throws -> RateLimitsReadResponse {
        let transport = try await initializedTransport(generation: generation)
        try ensureCurrent(transport, generation: generation)
        try await transport.send(
            #"{"method":"\#(AppServerMethod.rateLimitsRead.rawValue)","id":1,"params":null}"#
        )
        try ensureCurrent(transport, generation: generation)
        let response = try await waitForResponse(
            id: 1,
            result: RateLimitsReadResponse.self,
            transport: transport
        )
        try ensureCurrent(transport, generation: generation)
        return response
    }

    private func initializedTransport(generation: UInt64) async throws -> any JSONLineTransport {
        try ensureActive(generation: generation)
        if let transport {
            guard transport.generation == generation else {
                throw CancellationError()
            }
            return transport.value
        }

        let candidate = makeTransport()
        try ensureActive(generation: generation)
        transport = OwnedTransport(generation: generation, value: candidate)
        do {
            try await candidate.start()
            try ensureCurrent(candidate, generation: generation)
            try await candidate.send(
                #"{"method":"\#(AppServerMethod.initialize.rawValue)","id":0,"params":{"clientInfo":{"name":"codex_quota_menu","title":"Codex Quota Menu","version":"0.1.0"}}}"#
            )
            try ensureCurrent(candidate, generation: generation)
            _ = try await waitForResponse(
                id: 0,
                result: IgnoredResult.self,
                transport: candidate
            )
            try ensureCurrent(candidate, generation: generation)
            try await candidate.send(
                #"{"method":"\#(AppServerMethod.initialized.rawValue)","params":{}}"#
            )
            try ensureCurrent(candidate, generation: generation)
            return candidate
        } catch {
            await clearAndStop(candidate, generation: generation)
            throw error
        }
    }

    private func waitForResponse<Result: Decodable & Sendable>(
        id: Int,
        result: Result.Type,
        transport: any JSONLineTransport
    ) async throws -> Result {
        let outcomeGate = ResponseOutcomeGate()
        return try await withThrowingTaskGroup(of: ResponseRaceCompletion<Result>.self) { group in
            group.addTask {
                while true {
                    let line: String
                    do {
                        line = try await transport.receive()
                    } catch {
                        let won = await outcomeGate.claimResponse()
                        return won ? .failure(error) : .loser
                    }

                    let data = Data(line.utf8)
                    let header: MessageHeader
                    do {
                        header = try JSONDecoder().decode(MessageHeader.self, from: data)
                    } catch {
                        let won = await outcomeGate.claimResponse()
                        return won ? .failure(AppServerClientError.malformedResponse) : .loser
                    }
                    guard header.id?.matches(id) == true else { continue }

                    let response: RPCResponse<Result>
                    do {
                        response = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
                    } catch {
                        let won = await outcomeGate.claimResponse()
                        return won ? .failure(AppServerClientError.malformedResponse) : .loser
                    }
                    if let error = response.error {
                        let won = await outcomeGate.claimResponse()
                        return won
                            ? .failure(AppServerClientError.server(
                                code: error.code,
                                message: error.message
                            ))
                            : .loser
                    }
                    guard let result = response.result else {
                        let won = await outcomeGate.claimResponse()
                        return won ? .failure(AppServerClientError.malformedResponse) : .loser
                    }
                    let won = await outcomeGate.claimResponse()
                    return won ? .success(result) : .loser
                }
            }
            group.addTask { [timeoutSeconds, timeoutSleep] in
                do {
                    try await timeoutSleep(.seconds(timeoutSeconds))
                } catch {
                    return .loser
                }
                guard await outcomeGate.claimTimeout() else { return .loser }
                await transport.stop()
                return .failure(AppServerClientError.timeout)
            }

            while let completion = try await group.next() {
                switch completion {
                case .success(let response):
                    group.cancelAll()
                    return response
                case .failure(let error):
                    group.cancelAll()
                    throw error
                case .loser:
                    continue
                }
            }
            throw AppServerClientError.malformedResponse
        }
    }

    private func ensureActive(generation: UInt64) throws {
        try Task<Never, Never>.checkCancellation()
        guard case .active(let currentGeneration) = lifecycle,
              currentGeneration == generation else {
            throw CancellationError()
        }
    }

    private func ensureCurrent(
        _ candidate: any JSONLineTransport,
        generation: UInt64
    ) throws {
        try ensureActive(generation: generation)
        guard let transport,
              transport.generation == generation,
              transport.value === candidate else {
            throw CancellationError()
        }
    }

    private func clearAndStop(
        _ candidate: any JSONLineTransport,
        generation: UInt64
    ) async {
        if let transport,
           transport.generation == generation,
           transport.value === candidate {
            self.transport = nil
        }
        await candidate.stop()
    }

    private func resetTransport(generation: UInt64) async {
        guard let transport, transport.generation == generation else { return }
        self.transport = nil
        await transport.value.stop()
    }

    private func takeTransport(generation: UInt64) -> (any JSONLineTransport)? {
        guard let transport, transport.generation == generation else { return nil }
        self.transport = nil
        return transport.value
    }

    private func finishStop(generation: UInt64, readID: UInt64?) {
        guard case .stopping(let currentGeneration, _) = lifecycle,
              currentGeneration == generation else { return }
        if let readID {
            clearInFlightRead(id: readID, generation: generation)
        }
        lifecycle = .active(generation: generation &+ 1)
    }

    private func clearInFlightRead(id: UInt64, generation: UInt64) {
        guard inFlightRead?.id == id,
              inFlightRead?.generation == generation else { return }
        inFlightRead = nil
    }
}
