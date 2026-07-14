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
    let id: Int?
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

private actor TimeoutGate {
    private var timedOut = false

    var hasTimedOut: Bool { timedOut }

    func markTimedOut() {
        timedOut = true
    }
}

actor CodexAppServerClient: RateLimitsReading {
    private struct InFlightRead {
        let id: UInt64
        let task: Task<RateLimitsReadResponse, any Error>
    }

    private let makeTransport: @Sendable () -> any JSONLineTransport
    private let timeoutSeconds: TimeInterval
    private var transport: (any JSONLineTransport)?
    private var inFlightRead: InFlightRead?
    private var nextReadID: UInt64 = 0

    init(
        makeTransport: @escaping @Sendable () -> any JSONLineTransport,
        timeoutSeconds: TimeInterval = 10
    ) {
        self.makeTransport = makeTransport
        self.timeoutSeconds = timeoutSeconds.isFinite && timeoutSeconds > 0 ? timeoutSeconds : 0
    }

    func readRateLimits() async throws -> RateLimitsReadResponse {
        if let inFlightRead {
            return try await inFlightRead.task.value
        }

        nextReadID &+= 1
        let readID = nextReadID
        let task = Task { try await self.readWithOneRetry() }
        inFlightRead = InFlightRead(id: readID, task: task)

        do {
            let response = try await task.value
            clearInFlightRead(id: readID)
            return response
        } catch {
            clearInFlightRead(id: readID)
            throw error
        }
    }

    func stop() async {
        let read = inFlightRead
        read?.task.cancel()
        await resetTransport()

        if let read {
            _ = await read.task.result
            clearInFlightRead(id: read.id)
        }
        await resetTransport()
    }

    private func readWithOneRetry() async throws -> RateLimitsReadResponse {
        for attempt in 0..<2 {
            try Task<Never, Never>.checkCancellation()
            do {
                return try await readOnce()
            } catch {
                await resetTransport()
                try Task<Never, Never>.checkCancellation()
                if attempt == 1 {
                    throw error
                }
            }
        }
        throw AppServerClientError.malformedResponse
    }

    private func readOnce() async throws -> RateLimitsReadResponse {
        let transport = try await initializedTransport()
        try ensureCurrent(transport)
        try await transport.send(
            #"{"method":"\#(AppServerMethod.rateLimitsRead.rawValue)","id":1,"params":null}"#
        )
        try ensureCurrent(transport)
        let response = try await waitForResponse(
            id: 1,
            result: RateLimitsReadResponse.self,
            transport: transport
        )
        try ensureCurrent(transport)
        return response
    }

    private func initializedTransport() async throws -> any JSONLineTransport {
        if let transport {
            return transport
        }

        let candidate = makeTransport()
        transport = candidate
        do {
            try await candidate.start()
            try ensureCurrent(candidate)
            try await candidate.send(
                #"{"method":"\#(AppServerMethod.initialize.rawValue)","id":0,"params":{"clientInfo":{"name":"codex_quota_menu","title":"Codex Quota Menu","version":"0.1.0"}}}"#
            )
            try ensureCurrent(candidate)
            _ = try await waitForResponse(
                id: 0,
                result: IgnoredResult.self,
                transport: candidate
            )
            try ensureCurrent(candidate)
            try await candidate.send(
                #"{"method":"\#(AppServerMethod.initialized.rawValue)","params":{}}"#
            )
            try ensureCurrent(candidate)
            return candidate
        } catch {
            await clearAndStop(candidate)
            throw error
        }
    }

    private func waitForResponse<Result: Decodable & Sendable>(
        id: Int,
        result: Result.Type,
        transport: any JSONLineTransport
    ) async throws -> Result {
        let timeoutGate = TimeoutGate()
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                while true {
                    do {
                        let line = try await transport.receive()
                        if await timeoutGate.hasTimedOut {
                            throw AppServerClientError.timeout
                        }

                        let data = Data(line.utf8)
                        let header: MessageHeader
                        do {
                            header = try JSONDecoder().decode(MessageHeader.self, from: data)
                        } catch {
                            throw AppServerClientError.malformedResponse
                        }
                        guard header.id == id else { continue }

                        let response: RPCResponse<Result>
                        do {
                            response = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
                        } catch {
                            throw AppServerClientError.malformedResponse
                        }
                        if let error = response.error {
                            throw AppServerClientError.server(
                                code: error.code,
                                message: error.message
                            )
                        }
                        guard let result = response.result else {
                            throw AppServerClientError.malformedResponse
                        }
                        if await timeoutGate.hasTimedOut {
                            throw AppServerClientError.timeout
                        }
                        return result
                    } catch {
                        if await timeoutGate.hasTimedOut {
                            throw AppServerClientError.timeout
                        }
                        throw error
                    }
                }
            }
            group.addTask { [timeoutSeconds] in
                try await Task<Never, Never>.sleep(for: .seconds(timeoutSeconds))
                await timeoutGate.markTimedOut()
                await transport.stop()
                throw AppServerClientError.timeout
            }

            do {
                guard let response = try await group.next() else {
                    throw AppServerClientError.malformedResponse
                }
                group.cancelAll()
                return response
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func ensureCurrent(_ candidate: any JSONLineTransport) throws {
        try Task<Never, Never>.checkCancellation()
        guard let transport, transport === candidate else {
            throw CancellationError()
        }
    }

    private func clearAndStop(_ candidate: any JSONLineTransport) async {
        if let transport, transport === candidate {
            self.transport = nil
        }
        await candidate.stop()
    }

    private func resetTransport() async {
        let transport = transport
        self.transport = nil
        await transport?.stop()
    }

    private func clearInFlightRead(id: UInt64) {
        guard inFlightRead?.id == id else { return }
        inFlightRead = nil
    }
}
