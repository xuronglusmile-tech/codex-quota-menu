import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite(.serialized)
@MainActor
struct QuotaStoreTests {
    @Test
    func testRefreshIntervalIsExactlyFiveMinutes() {
        #expect(QuotaStore.refreshIntervalSeconds == 300)
    }

    @Test
    func testLoadsCacheThenRefreshesAndReconcilesNotifications() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let cached = Self.snapshot(fetchedAt: now.addingTimeInterval(-60), count: 2)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let cache = MemoryQuotaCache(snapshot: cached)
        let notifications = RecordingNotifications()
        let store = QuotaStore(
            reader: StubQuotaReader(result: .success(live)),
            cache: cache,
            notifications: notifications,
            now: { now }
        )

        await store.loadCache()
        #expect(store.state == .fresh(cached))
        await store.refresh()

        #expect(store.state == .fresh(live))
        #expect(await notifications.snapshots == [live])
        #expect(store.lastErrorMessage == nil)
    }

    @Test
    func testStartLoadsCacheBeforeItsImmediateRefresh() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let cached = Self.snapshot(fetchedAt: now.addingTimeInterval(-60), count: 2)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let reader = BlockingQuotaReader()
        let sleeper = ControlledStoreSleeper()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: cached),
            notifications: RecordingNotifications(),
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await reader.waitUntilReadCount(1)

        #expect(store.state == .fresh(cached))
        await reader.resumeNext(returning: live)
        await sleeper.waitUntilRequestCount(1)
        #expect(store.state == .fresh(live))

        await store.stop()
    }

    @Test
    func testLaunchAndEveryAutomaticDelayRequestExactlyThreeHundredSeconds() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let reader = SequenceQuotaReader(snapshots: [
            Self.snapshot(fetchedAt: now, count: 1),
            Self.snapshot(fetchedAt: now.addingTimeInterval(300), count: 2)
        ])
        let sleeper = ControlledStoreSleeper()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await sleeper.waitUntilRequestCount(1)
        #expect(await reader.readCount == 1)
        #expect(await sleeper.requestedSeconds == [300])

        await sleeper.resumeNext()
        await sleeper.waitUntilRequestCount(2)
        #expect(await reader.readCount == 2)
        #expect(await sleeper.requestedSeconds == [300, 300])

        await store.stop()
    }

    @Test
    func testConcurrentRefreshesCoalesceToOneRead() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let reader = BlockingQuotaReader()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now }
        )

        let first = Task { await store.refresh() }
        await reader.waitUntilReadCount(1)
        let second = Task { await store.refresh() }
        await Task<Never, Never>.yield()

        #expect(await reader.readCount == 1)
        await reader.resumeNext(returning: live)
        await first.value
        await second.value
        #expect(store.state == .fresh(live))
    }

    @Test
    func testManualRefreshCoalescesWithLaunchRefresh() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let reader = BlockingQuotaReader()
        let sleeper = ControlledStoreSleeper()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await reader.waitUntilReadCount(1)
        let manual = Task { await store.refresh() }
        await Task<Never, Never>.yield()

        #expect(await reader.readCount == 1)
        await reader.resumeNext(returning: live)
        await manual.value
        await sleeper.waitUntilRequestCount(1)
        #expect(store.state == .fresh(live))

        await store.stop()
    }

    @Test
    func testFailureMarksCacheStaleAtExactBoundaryAndRetainsValues() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let old = Self.snapshot(fetchedAt: now.addingTimeInterval(-1_800), count: 5)
        let store = QuotaStore(
            reader: StubQuotaReader(result: .failure(TestStoreError.readFailed)),
            cache: MemoryQuotaCache(snapshot: old),
            notifications: RecordingNotifications(),
            now: { now }
        )

        await store.loadCache()
        await store.refresh()

        guard case .stale(let snapshot, let message) = store.state else {
            Issue.record("Expected stale state")
            return
        }
        #expect(snapshot.availableResetCount == 5)
        #expect(message == TestStoreError.readFailed.localizedDescription)
    }

    @Test
    func testFailureBeforeStaleBoundaryKeepsFreshSnapshotAndSurfacesError() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let recent = Self.snapshot(fetchedAt: now.addingTimeInterval(-1_799), count: 5)
        let store = QuotaStore(
            reader: StubQuotaReader(result: .failure(TestStoreError.readFailed)),
            cache: MemoryQuotaCache(snapshot: recent),
            notifications: RecordingNotifications(),
            now: { now }
        )

        await store.loadCache()
        await store.refresh()

        #expect(store.state == .fresh(recent))
        #expect(store.lastErrorMessage == TestStoreError.readFailed.localizedDescription)
    }

    @Test
    func testFailureWithoutSnapshotBecomesUnavailable() async {
        let store = QuotaStore(
            reader: StubQuotaReader(result: .failure(TestStoreError.readFailed)),
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications()
        )

        await store.refresh()

        #expect(store.state == .unavailable(message: TestStoreError.readFailed.localizedDescription))
        #expect(store.lastErrorMessage == TestStoreError.readFailed.localizedDescription)
    }

    @Test
    func testCacheSaveFailureKeepsLiveDataFreshAndStillReconcilesNotifications() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let notifications = RecordingNotifications()
        let store = QuotaStore(
            reader: StubQuotaReader(result: .success(live)),
            cache: MemoryQuotaCache(snapshot: nil, failSaves: true),
            notifications: notifications,
            now: { now }
        )

        await store.refresh()

        #expect(store.state == .fresh(live))
        #expect(store.lastErrorMessage == TestStoreError.cacheSaveFailed.localizedDescription)
        #expect(await notifications.snapshots == [live])
    }

    @Test
    func testStopDuringReadShutsDownReaderAndPreventsCancellationErrorState() async {
        let reader = ShutdownUnblockingQuotaReader()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications()
        )

        store.start()
        await reader.waitUntilReadStarts()
        await store.stop()

        #expect(await reader.shutdownCount == 1)
        #expect(store.state == .loading)
        #expect(store.lastErrorMessage == nil)
        #expect(!store.isRefreshing)
    }

    @Test
    func testStopDuringSleepIsAwaitedIdempotentAndPreventsAnotherRead() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let reader = SequenceQuotaReader(snapshots: [Self.snapshot(fetchedAt: now, count: 1)])
        let sleeper = ControlledStoreSleeper()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await sleeper.waitUntilRequestCount(1)
        await store.stop()
        await store.stop()

        #expect(await sleeper.cancellationCount == 1)
        #expect(await reader.readCount == 1)
        #expect(await reader.shutdownCount == 1)
        #expect(!store.isRefreshing)
    }

    @Test
    func testStoppedStoreCanRestartWithFreshLoopAndReaderGeneration() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let first = Self.snapshot(fetchedAt: now, count: 1)
        let second = Self.snapshot(fetchedAt: now.addingTimeInterval(1), count: 2)
        let reader = SequenceQuotaReader(snapshots: [first, second])
        let sleeper = ControlledStoreSleeper()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await sleeper.waitUntilRequestCount(1)
        #expect(store.state == .fresh(first))
        await store.stop()

        store.start()
        await sleeper.waitUntilRequestCount(2)
        #expect(store.state == .fresh(second))
        #expect(await reader.readCount == 2)
        #expect(await reader.shutdownCount == 1)

        await store.stop()
        #expect(await reader.shutdownCount == 2)
    }

    @Test
    func testStopAwaitsOldReadAndOldGenerationCannotMutateRestartedState() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let old = Self.snapshot(fetchedAt: now, count: 1)
        let live = Self.snapshot(fetchedAt: now.addingTimeInterval(1), count: 9)
        let reader = OldGenerationQuotaReader(nextGenerationSnapshot: live)
        let sleeper = ControlledStoreSleeper()
        let completion = CompletionProbe()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await reader.waitUntilFirstReadStarts()
        let stop = Task {
            await store.stop()
            await completion.markFinished()
        }
        await reader.waitUntilShutdownCount(1)
        await Task<Never, Never>.yield()
        #expect(!(await completion.isFinished))

        await reader.resumeFirst(returning: old)
        await stop.value
        #expect(store.state == .loading)

        store.start()
        await sleeper.waitUntilRequestCount(1)
        #expect(store.state == .fresh(live))
        #expect(await reader.readCount == 2)

        await store.stop()
    }

    @Test
    func testStopDuringStartupPermissionReadPreventsPostStopStateMutation() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let cached = Self.snapshot(fetchedAt: now, count: 4)
        let reader = SequenceQuotaReader(snapshots: [cached])
        let notifications = SuspendedPermissionNotifications(
            enabled: false,
            permission: .denied
        )
        let completion = CompletionProbe()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: cached),
            notifications: notifications,
            now: { now }
        )

        store.start()
        await notifications.waitUntilPermissionStateIsSuspended()
        let stateBeforeStop = store.state
        let enabledBeforeStop = store.notificationsEnabled
        let permissionBeforeStop = store.notificationPermission

        let stop = Task {
            await store.stop()
            await completion.markFinished()
        }
        await reader.waitUntilShutdownCount(1)
        #expect(!(await completion.isFinished))

        await notifications.resumePermissionState()
        await stop.value

        #expect(store.state == stateBeforeStop)
        #expect(store.notificationsEnabled == enabledBeforeStop)
        #expect(store.notificationPermission == permissionBeforeStop)
        #expect(store.notificationPermission == .unknown)
        #expect(await reader.readCount == 0)
    }

    @Test
    func testOlderNotificationPreferenceCompletionCannotOverrideNewerCall() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let snapshot = Self.snapshot(fetchedAt: now, count: 4)
        let notifications = ReverseCompletionNotifications()
        let store = QuotaStore(
            reader: StubQuotaReader(result: .success(snapshot)),
            cache: MemoryQuotaCache(snapshot: snapshot),
            notifications: notifications,
            now: { now }
        )
        await store.loadCache()

        let older = Task { await store.setNotificationsEnabled(true) }
        await notifications.waitUntilSetCallCount(1)
        let newer = Task { await store.setNotificationsEnabled(false) }
        await notifications.waitUntilSetCallCount(2)

        await notifications.completeSetCall(
            at: 1,
            enabledResult: false,
            permissionResult: .denied
        )
        await newer.value
        #expect(!store.notificationsEnabled)
        #expect(store.notificationPermission == .denied)

        await notifications.completeSetCall(
            at: 0,
            enabledResult: true,
            permissionResult: .authorized
        )
        await older.value

        #expect(store.notificationsEnabled == (await notifications.persistedEnabled))
        #expect(!store.notificationsEnabled)
        #expect(store.notificationPermission == .denied)
        #expect(await notifications.reconciledSnapshots.isEmpty)
        #expect(store.state == .fresh(snapshot))
    }

    @Test
    func testStartupNotificationResultCannotOverrideSameRunUserToggle() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let snapshot = Self.snapshot(fetchedAt: now, count: 4)
        let reader = SequenceQuotaReader(snapshots: [snapshot])
        let notifications = StartupToggleNotifications()
        let sleeper = ControlledStoreSleeper()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: snapshot),
            notifications: notifications,
            now: { now },
            sleep: { try await sleeper.sleep(seconds: $0) }
        )

        store.start()
        await notifications.waitUntilStartupEnabledReadIsSuspended()
        await store.setNotificationsEnabled(false)
        #expect(!store.notificationsEnabled)
        #expect(store.notificationPermission == .denied)

        await notifications.resumeStartupEnabledRead()
        await sleeper.waitUntilRequestCount(1)

        #expect(store.notificationsEnabled == (await notifications.persistedEnabled))
        #expect(!store.notificationsEnabled)
        #expect(store.notificationPermission == .denied)
        #expect(store.state == .fresh(snapshot))
        #expect(await notifications.authorizationRequestCount == 0)

        await store.stop()
    }

    @Test
    func testConcurrentStopCallersAwaitFinalizationAndSecondaryCanRestartImmediately() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let restartSnapshot = Self.snapshot(fetchedAt: now, count: 8)
        let reader = SuspendedCleanupQuotaReader(restartSnapshot: restartSnapshot)
        let primaryCompletion = StopCallerProbe()
        let secondaryCompletion = StopCallerProbe()
        let store = QuotaStore(
            reader: reader,
            cache: MemoryQuotaCache(snapshot: nil),
            notifications: RecordingNotifications(),
            now: { now }
        )

        store.start()
        await reader.waitUntilReadCount(1)
        #expect(store.isRefreshing)

        let primary = Task(priority: .background) { @MainActor in
            await store.stop()
            await primaryCompletion.markFinished(observedFinalized: !store.isRefreshing)
        }
        await reader.waitUntilShutdownStarts()
        let secondary = Task(priority: .high) { @MainActor in
            await secondaryCompletion.markStarted()
            await store.stop()
            let finalized = !store.isRefreshing
            store.start()
            await secondaryCompletion.markFinished(observedFinalized: finalized)
        }
        await secondaryCompletion.waitUntilStarted()
        for _ in 0..<10 {
            await Task<Never, Never>.yield()
        }

        #expect(!(await primaryCompletion.isFinished))
        #expect(!(await secondaryCompletion.isFinished))
        await reader.resumeFirstShutdown()
        let secondaryFinished = await secondaryCompletion.waitForFinished(maximumYields: 1_000)
        #expect(secondaryFinished)
        guard secondaryFinished else {
            primary.cancel()
            secondary.cancel()
            return
        }
        await secondary.value

        #expect(await secondaryCompletion.observedFinalized)
        let restarted = await reader.waitForReadCount(2, maximumYields: 1_000)
        #expect(restarted)
        if restarted {
            #expect(store.state == .fresh(restartSnapshot))
        }
        #expect(await reader.shutdownCount == 1)

        let primaryFinished = await primaryCompletion.waitForFinished(maximumYields: 1_000)
        #expect(primaryFinished)
        guard primaryFinished else {
            primary.cancel()
            return
        }
        await primary.value
        #expect(await primaryCompletion.observedFinalized)
        await store.stop()
        #expect(await reader.shutdownCount == 2)
    }

    @Test
    func testNotificationSettingUpdatesPermissionWithoutChangingQuotaState() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let notifications = RecordingNotifications(permission: .denied)
        let store = QuotaStore(
            reader: StubQuotaReader(result: .success(live)),
            cache: MemoryQuotaCache(snapshot: live),
            notifications: notifications,
            now: { now }
        )

        await store.loadCache()
        await store.setNotificationsEnabled(false)

        #expect(!store.notificationsEnabled)
        #expect(store.notificationPermission == .denied)
        #expect(store.state == .fresh(live))
        #expect(await notifications.enabledValues == [false])
    }

    @Test
    func testUrgencyIncludesExactFutureDayAndExcludesExpiredNonexpiringAndFarFuture() {
        let now = Date(timeIntervalSince1970: 5_000)

        #expect(ResetCreditUrgency.isUrgent(expiresAt: now.addingTimeInterval(1), now: now))
        #expect(ResetCreditUrgency.isUrgent(expiresAt: now.addingTimeInterval(86_400), now: now))
        #expect(!ResetCreditUrgency.isUrgent(expiresAt: now, now: now))
        #expect(!ResetCreditUrgency.isUrgent(expiresAt: now.addingTimeInterval(-1), now: now))
        #expect(!ResetCreditUrgency.isUrgent(expiresAt: nil, now: now))
        #expect(!ResetCreditUrgency.isUrgent(expiresAt: now.addingTimeInterval(86_401), now: now))
    }

    @Test
    func testUrgentStatusTextIsVisibleOnlyForFutureCreditsWithinOneDay() {
        let now = Date(timeIntervalSince1970: 5_000)

        #expect(
            ResetCreditUrgency.statusText(
                expiresAt: now.addingTimeInterval(86_400),
                now: now
            ) == "即将到期"
        )
        #expect(ResetCreditUrgency.statusText(expiresAt: now, now: now) == nil)
        #expect(
            ResetCreditUrgency.statusText(
                expiresAt: now.addingTimeInterval(86_401),
                now: now
            ) == nil
        )
    }

    private static func snapshot(fetchedAt: Date, count: Int) -> QuotaSnapshot {
        QuotaSnapshot(
            windows: [
                QuotaWindow(
                    id: "weekly",
                    label: "每周额度",
                    usedPercent: 53,
                    durationMinutes: 10_080,
                    resetsAt: nil
                )
            ],
            availableResetCount: count,
            resetCredits: [],
            fetchedAt: fetchedAt
        )
    }
}

private enum TestStoreError: LocalizedError {
    case readFailed
    case cacheSaveFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: "read failed"
        case .cacheSaveFailed: "cache save failed"
        }
    }
}

private actor StubQuotaReader: QuotaReading {
    let result: Result<QuotaSnapshot, TestStoreError>
    private(set) var shutdownCount = 0

    init(result: Result<QuotaSnapshot, TestStoreError>) {
        self.result = result
    }

    func read() async throws -> QuotaSnapshot {
        try result.get()
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor SequenceQuotaReader: QuotaReading {
    private var snapshots: [QuotaSnapshot]
    private var shutdownWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var readCount = 0
    private(set) var shutdownCount = 0

    init(snapshots: [QuotaSnapshot]) {
        self.snapshots = snapshots
    }

    func read() async throws -> QuotaSnapshot {
        readCount += 1
        guard !snapshots.isEmpty else { throw TestStoreError.readFailed }
        return snapshots.removeFirst()
    }

    func shutdown() async {
        shutdownCount += 1
        let ready = shutdownWaiters.filter { $0.0 <= shutdownCount }
        shutdownWaiters.removeAll { $0.0 <= shutdownCount }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilShutdownCount(_ target: Int) async {
        guard shutdownCount < target else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append((target, continuation))
        }
    }
}

private actor BlockingQuotaReader: QuotaReading {
    private var continuations: [CheckedContinuation<QuotaSnapshot, any Error>] = []
    private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var readCount = 0

    func read() async throws -> QuotaSnapshot {
        readCount += 1
        resumeReadWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func shutdown() async {}

    func waitUntilReadCount(_ target: Int) async {
        guard readCount < target else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append((target, continuation))
        }
    }

    func resumeNext(returning snapshot: QuotaSnapshot) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: snapshot)
    }

    private func resumeReadWaiters() {
        let ready = readWaiters.filter { $0.0 <= readCount }
        readWaiters.removeAll { $0.0 <= readCount }
        ready.forEach { $0.1.resume() }
    }
}

private actor ShutdownUnblockingQuotaReader: QuotaReading {
    private var continuation: CheckedContinuation<QuotaSnapshot, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var readStarted = false
    private(set) var shutdownCount = 0

    func read() async throws -> QuotaSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            readStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func shutdown() async {
        shutdownCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilReadStarts() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor OldGenerationQuotaReader: QuotaReading {
    private let nextGenerationSnapshot: QuotaSnapshot
    private var firstContinuation: CheckedContinuation<QuotaSnapshot, any Error>?
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var readCount = 0
    private(set) var shutdownCount = 0

    init(nextGenerationSnapshot: QuotaSnapshot) {
        self.nextGenerationSnapshot = nextGenerationSnapshot
    }

    func read() async throws -> QuotaSnapshot {
        readCount += 1
        if readCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
                let waiters = firstReadWaiters
                firstReadWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return nextGenerationSnapshot
    }

    func shutdown() async {
        shutdownCount += 1
        let ready = shutdownWaiters.filter { $0.0 <= shutdownCount }
        shutdownWaiters.removeAll { $0.0 <= shutdownCount }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilFirstReadStarts() async {
        guard firstContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            firstReadWaiters.append(continuation)
        }
    }

    func waitUntilShutdownCount(_ target: Int) async {
        guard shutdownCount < target else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append((target, continuation))
        }
    }

    func resumeFirst(returning snapshot: QuotaSnapshot) {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: snapshot)
    }
}

private actor MemoryQuotaCache: QuotaCaching {
    private var snapshot: QuotaSnapshot?
    private let failSaves: Bool

    init(snapshot: QuotaSnapshot?, failSaves: Bool = false) {
        self.snapshot = snapshot
        self.failSaves = failSaves
    }

    func load() async -> QuotaSnapshot? {
        snapshot
    }

    func save(_ snapshot: QuotaSnapshot) async throws {
        guard !failSaves else { throw TestStoreError.cacheSaveFailed }
        self.snapshot = snapshot
    }
}

private actor RecordingNotifications: ExpiryNotificationReconciling {
    private(set) var snapshots: [QuotaSnapshot] = []
    private(set) var enabledValues: [Bool] = []
    private var enabled = true
    private let permission: NotificationPermissionState

    init(permission: NotificationPermissionState = .authorized) {
        self.permission = permission
    }

    func requestAuthorization() async {}

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {
        snapshots.append(snapshot)
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        enabledValues.append(enabled)
    }

    func isEnabled() async -> Bool {
        enabled
    }

    func permissionState() async -> NotificationPermissionState {
        permission
    }
}

private actor SuspendedPermissionNotifications: ExpiryNotificationReconciling {
    private let enabled: Bool
    private let permission: NotificationPermissionState
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(enabled: Bool, permission: NotificationPermissionState) {
        self.enabled = enabled
        self.permission = permission
    }

    func requestAuthorization() async {}

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {}

    func setEnabled(_ enabled: Bool) async {}

    func isEnabled() async -> Bool {
        enabled
    }

    func permissionState() async -> NotificationPermissionState {
        await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return permission
    }

    func waitUntilPermissionStateIsSuspended() async {
        guard permissionContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumePermissionState() {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume()
    }
}

private struct NotificationReadResult {
    let enabled: Bool
    let permission: NotificationPermissionState
}

private actor ReverseCompletionNotifications: ExpiryNotificationReconciling {
    private var persisted = true
    private var setContinuations: [CheckedContinuation<Void, Never>?] = []
    private var setCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var readResults: [NotificationReadResult] = []
    private var pendingPermissions: [NotificationPermissionState] = []
    private(set) var reconciledSnapshots: [QuotaSnapshot] = []

    var persistedEnabled: Bool {
        persisted
    }

    func requestAuthorization() async {}

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {
        reconciledSnapshots.append(snapshot)
    }

    func setEnabled(_ enabled: Bool) async {
        persisted = enabled
        let index = setContinuations.count
        setContinuations.append(nil)
        resumeSetCallWaiters()
        await withCheckedContinuation { continuation in
            setContinuations[index] = continuation
        }
    }

    func isEnabled() async -> Bool {
        guard !readResults.isEmpty else { return persisted }
        let result = readResults.removeFirst()
        pendingPermissions.append(result.permission)
        return result.enabled
    }

    func permissionState() async -> NotificationPermissionState {
        guard !pendingPermissions.isEmpty else {
            return persisted ? .authorized : .denied
        }
        return pendingPermissions.removeFirst()
    }

    func waitUntilSetCallCount(_ target: Int) async {
        guard setContinuations.count < target else { return }
        await withCheckedContinuation { continuation in
            setCallWaiters.append((target, continuation))
        }
    }

    func completeSetCall(
        at index: Int,
        enabledResult: Bool,
        permissionResult: NotificationPermissionState
    ) {
        readResults.append(
            NotificationReadResult(
                enabled: enabledResult,
                permission: permissionResult
            )
        )
        let continuation = setContinuations[index]
        setContinuations[index] = nil
        continuation?.resume()
    }

    private func resumeSetCallWaiters() {
        let ready = setCallWaiters.filter { $0.0 <= setContinuations.count }
        setCallWaiters.removeAll { $0.0 <= setContinuations.count }
        ready.forEach { $0.1.resume() }
    }
}

private actor StartupToggleNotifications: ExpiryNotificationReconciling {
    private var persisted = true
    private var permission = NotificationPermissionState.denied
    private var enabledReadCount = 0
    private var startupEnabledContinuation: CheckedContinuation<Void, Never>?
    private var startupEnabledWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var authorizationRequestCount = 0

    var persistedEnabled: Bool {
        persisted
    }

    func requestAuthorization() async {
        authorizationRequestCount += 1
        permission = .authorized
    }

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {}

    func setEnabled(_ enabled: Bool) async {
        persisted = enabled
        permission = enabled ? .authorized : .denied
    }

    func isEnabled() async -> Bool {
        enabledReadCount += 1
        if enabledReadCount == 1 {
            await withCheckedContinuation { continuation in
                startupEnabledContinuation = continuation
                let waiters = startupEnabledWaiters
                startupEnabledWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            return true
        }
        return persisted
    }

    func permissionState() async -> NotificationPermissionState {
        permission
    }

    func waitUntilStartupEnabledReadIsSuspended() async {
        guard startupEnabledContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startupEnabledWaiters.append(continuation)
        }
    }

    func resumeStartupEnabledRead() {
        let continuation = startupEnabledContinuation
        startupEnabledContinuation = nil
        continuation?.resume()
    }
}

private actor SuspendedCleanupQuotaReader: QuotaReading {
    private let restartSnapshot: QuotaSnapshot
    private var firstReadContinuation: CheckedContinuation<QuotaSnapshot, any Error>?
    private var firstShutdownContinuation: CheckedContinuation<Void, Never>?
    private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var shutdownStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    private(set) var shutdownCount = 0

    init(restartSnapshot: QuotaSnapshot) {
        self.restartSnapshot = restartSnapshot
    }

    func read() async throws -> QuotaSnapshot {
        readCount += 1
        resumeReadWaiters()
        if readCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstReadContinuation = continuation
            }
        }
        return restartSnapshot
    }

    func shutdown() async {
        shutdownCount += 1
        guard shutdownCount == 1 else { return }
        let waiters = shutdownStartWaiters
        shutdownStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstShutdownContinuation = continuation
        }
    }

    func waitUntilReadCount(_ target: Int) async {
        guard readCount < target else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append((target, continuation))
        }
    }

    func waitForReadCount(_ target: Int, maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if readCount >= target { return true }
            await Task<Never, Never>.yield()
        }
        return readCount >= target
    }

    func waitUntilShutdownStarts() async {
        guard firstShutdownContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            shutdownStartWaiters.append(continuation)
        }
    }

    func resumeFirstShutdown() {
        let readContinuation = firstReadContinuation
        firstReadContinuation = nil
        readContinuation?.resume(throwing: CancellationError())
        let shutdownContinuation = firstShutdownContinuation
        firstShutdownContinuation = nil
        shutdownContinuation?.resume()
    }

    private func resumeReadWaiters() {
        let ready = readWaiters.filter { $0.0 <= readCount }
        readWaiters.removeAll { $0.0 <= readCount }
        ready.forEach { $0.1.resume() }
    }
}

private actor StopCallerProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isFinished = false
    private(set) var observedFinalized = false

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markFinished(observedFinalized: Bool) {
        self.observedFinalized = observedFinalized
        isFinished = true
    }

    func waitForFinished(maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if isFinished { return true }
            await Task<Never, Never>.yield()
        }
        return isFinished
    }
}

private actor ControlledStoreSleeper {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var continuationOrder: [UUID] = []
    private var cancelled: Set<UUID> = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requestedSeconds: [TimeInterval] = []
    private(set) var cancellationCount = 0

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        requestedSeconds.append(seconds)
        resumeRequestWaiters()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || cancelled.remove(id) != nil {
                    cancellationCount += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[id] = continuation
                    continuationOrder.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilRequestCount(_ target: Int) async {
        guard requestedSeconds.count < target else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((target, continuation))
        }
    }

    func resumeNext() {
        guard !continuationOrder.isEmpty else { return }
        let id = continuationOrder.removeFirst()
        continuations.removeValue(forKey: id)?.resume()
    }

    private func cancel(id: UUID) {
        continuationOrder.removeAll { $0 == id }
        if let continuation = continuations.removeValue(forKey: id) {
            cancellationCount += 1
            continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { $0.0 <= requestedSeconds.count }
        requestWaiters.removeAll { $0.0 <= requestedSeconds.count }
        ready.forEach { $0.1.resume() }
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
