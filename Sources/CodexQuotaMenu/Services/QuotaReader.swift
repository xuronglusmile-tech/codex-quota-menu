import Foundation

protocol QuotaReading: Sendable {
    func read() async throws -> QuotaSnapshot
    func shutdown() async
}

struct LiveQuotaReader: QuotaReading {
    let client: any CodexAccountReading
    let now: @Sendable () -> Date
    let calendar: Calendar

    init(
        client: any CodexAccountReading,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.client = client
        self.now = now
        self.calendar = calendar
    }

    func read() async throws -> QuotaSnapshot {
        let response = try await client.readAccountSnapshot()
        let fetchedAt = now()
        let monthlyUsage: MonthlyUsage?
        if let buckets = response.usage?.dailyUsageBuckets {
            monthlyUsage = try? MonthlyUsageMapper.map(
                buckets: buckets,
                now: fetchedAt,
                calendar: calendar
            )
        } else {
            monthlyUsage = nil
        }
        return try QuotaResponseMapper.map(
            response.rateLimits,
            monthlyUsage: monthlyUsage,
            fetchedAt: fetchedAt
        )
    }

    func shutdown() async {}
}

protocol ProductionAccountClient: CodexAccountReading, AnyObject {
    func stop() async
}

extension CodexAppServerClient: ProductionAccountClient {}

actor ProductionQuotaReader: QuotaReading {
    private enum LifecycleState {
        case active(generation: UInt64)
        case stopping(generation: UInt64, task: Task<Void, Never>?)
    }

    typealias ClientFactory = @Sendable (
        URL,
        [String]
    ) -> any ProductionAccountClient

    private struct OwnedClient {
        let generation: UInt64
        let value: any ProductionAccountClient
    }

    private let locator: any CodexExecutableLocating
    private let makeClient: ClientFactory
    private let now: @Sendable () -> Date
    private var lifecycle = LifecycleState.active(generation: 0)
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
        guard case .active(let generation) = lifecycle else {
            throw CancellationError()
        }
        let ownedClient = try client(for: generation)
        let snapshot = try await LiveQuotaReader(
            client: ownedClient,
            now: now
        ).read()

        try Task<Never, Never>.checkCancellation()
        guard
            case .active(let currentGeneration) = lifecycle,
            currentGeneration == generation,
            let client,
            client.generation == generation,
            client.value === ownedClient
        else {
            throw CancellationError()
        }
        return snapshot
    }

    func shutdown() async {
        while true {
            switch lifecycle {
            case .active(let generation):
                guard let client else { return }
                lifecycle = .stopping(generation: generation, task: nil)
                self.client = nil

                let task = Task { [weak self] in
                    await client.value.stop()
                    guard let self else { return }
                    await self.finishShutdown(generation: generation)
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

    private func client(
        for generation: UInt64
    ) throws -> any ProductionAccountClient {
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

    private func finishShutdown(generation: UInt64) {
        guard case .stopping(let currentGeneration, _) = lifecycle,
              currentGeneration == generation else {
            return
        }
        lifecycle = .active(generation: generation &+ 1)
    }
}
