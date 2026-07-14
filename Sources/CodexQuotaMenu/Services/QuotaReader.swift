import Foundation

protocol QuotaReading: Sendable {
    func read() async throws -> QuotaSnapshot
    func shutdown() async
}

struct LiveQuotaReader: QuotaReading {
    let client: any RateLimitsReading
    let now: @Sendable () -> Date

    init(
        client: any RateLimitsReading,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.now = now
    }

    func read() async throws -> QuotaSnapshot {
        let response = try await client.readRateLimits()
        return try QuotaResponseMapper.map(response, fetchedAt: now())
    }

    func shutdown() async {}
}

protocol ProductionRateLimitsClient: RateLimitsReading, AnyObject {
    func stop() async
}

extension CodexAppServerClient: ProductionRateLimitsClient {}

actor ProductionQuotaReader: QuotaReading {
    typealias ClientFactory = @Sendable (
        URL,
        [String]
    ) -> any ProductionRateLimitsClient

    private struct OwnedClient {
        let generation: UInt64
        let value: any ProductionRateLimitsClient
    }

    private let locator: any CodexExecutableLocating
    private let makeClient: ClientFactory
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var client: OwnedClient?

    init(
        locator: any CodexExecutableLocating = CodexExecutableLocator(),
        makeClient: @escaping ClientFactory = { executable, arguments in
            CodexAppServerClient(makeTransport: {
                ProcessJSONLineTransport(
                    executableURL: executable,
                    arguments: arguments
                )
            })
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.makeClient = makeClient
        self.now = now
    }

    func read() async throws -> QuotaSnapshot {
        let generation = generation
        let ownedClient = try client(for: generation)
        let snapshot = try await LiveQuotaReader(
            client: ownedClient,
            now: now
        ).read()

        try Task<Never, Never>.checkCancellation()
        guard
            let client,
            client.generation == generation,
            client.value === ownedClient
        else {
            throw CancellationError()
        }
        return snapshot
    }

    func shutdown() async {
        generation &+= 1
        guard let client else { return }
        self.client = nil
        await client.value.stop()
    }

    private func client(
        for generation: UInt64
    ) throws -> any ProductionRateLimitsClient {
        if let client {
            guard client.generation == generation else {
                throw CancellationError()
            }
            return client.value
        }

        let executable = try locator.locate()
        let client = makeClient(executable, ["app-server", "--stdio"])
        self.client = OwnedClient(generation: generation, value: client)
        return client
    }
}
