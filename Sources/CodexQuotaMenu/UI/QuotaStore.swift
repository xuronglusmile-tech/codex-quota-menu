import Combine
import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    static let refreshIntervalSeconds: TimeInterval = 300

    @Published private(set) var state: QuotaDisplayState = .loading
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var notificationsEnabled = true
    @Published private(set) var notificationPermission: NotificationPermissionState = .unknown

    private struct OwnedTask {
        let id: UInt64
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let reader: any QuotaReading
    private let cache: any QuotaCaching
    private let notifications: any ExpiryNotificationReconciling
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var generation: UInt64 = 0
    private var nextTaskID: UInt64 = 0
    private var notificationOperationRevision: UInt64 = 0
    private var isStarted = false
    private var refreshTask: OwnedTask?
    private var loopTask: OwnedTask?
    private var stopTask: OwnedTask?

    init(
        reader: any QuotaReading,
        cache: any QuotaCaching,
        notifications: any ExpiryNotificationReconciling,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task<Never, Never>.sleep(for: .seconds(seconds))
        }
    ) {
        self.reader = reader
        self.cache = cache
        self.notifications = notifications
        self.now = now
        self.sleep = sleep
    }

    var menuTitle: String {
        MenuBarPresentation.title(for: state)
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        let operationGeneration = generation
        guard stopTask == nil else { return }
        let operationRevision = beginNotificationOperation()

        await notifications.setEnabled(enabled)
        guard canPublishNotificationOperation(
            generation: operationGeneration,
            revision: operationRevision
        ) else {
            return
        }
        let storedEnabled = await notifications.isEnabled()
        guard canPublishNotificationOperation(
            generation: operationGeneration,
            revision: operationRevision
        ) else {
            return
        }
        let permission = await notifications.permissionState()
        guard canPublishNotificationOperation(
            generation: operationGeneration,
            revision: operationRevision
        ) else {
            return
        }

        notificationsEnabled = storedEnabled
        notificationPermission = permission
        guard storedEnabled, let snapshot = state.snapshot else { return }
        guard canPublishNotificationOperation(
            generation: operationGeneration,
            revision: operationRevision
        ) else {
            return
        }
        await notifications.reconcile(snapshot: snapshot, now: now())
    }

    func loadCache() async {
        await loadCache(generation: generation)
    }

    func refresh() async {
        guard stopTask == nil else { return }
        await refresh(generation: generation)
    }

    func start() {
        guard
            !isStarted,
            stopTask == nil,
            refreshTask == nil,
            loopTask == nil
        else {
            return
        }

        generation &+= 1
        let startGeneration = generation
        let startupNotificationRevision = beginNotificationOperation()
        isStarted = true

        let loopID = makeTaskID()
        let loop = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLoop(
                generation: startGeneration,
                id: loopID,
                notificationRevision: startupNotificationRevision
            )
        }
        loopTask = OwnedTask(
            id: loopID,
            generation: startGeneration,
            task: loop
        )
    }

    func stop() async {
        if let stopTask {
            await stopTask.task.value
            return
        }
        guard
            isStarted || refreshTask != nil || loopTask != nil
        else {
            return
        }

        generation &+= 1
        isStarted = false

        let refresh = refreshTask
        let loop = loopTask

        refresh?.task.cancel()
        loop?.task.cancel()

        let reader = reader
        let stopID = makeTaskID()
        let task = Task { @MainActor [weak self] in
            await reader.shutdown()
            await refresh?.task.value
            await loop?.task.value
            self?.finishStop(id: stopID)
        }
        stopTask = OwnedTask(id: stopID, generation: generation, task: task)
        await task.value
    }

    private func runLoop(
        generation: UInt64,
        id: UInt64,
        notificationRevision: UInt64
    ) async {
        await loadCache(generation: generation)
        guard isRunning(generation: generation) else {
            finishLoop(generation: generation, id: id)
            return
        }

        await initializeNotifications(
            generation: generation,
            revision: notificationRevision
        )
        guard isRunning(generation: generation) else {
            finishLoop(generation: generation, id: id)
            return
        }

        await refresh(generation: generation)
        while isRunning(generation: generation) {
            do {
                try await sleep(Self.refreshIntervalSeconds)
            } catch {
                break
            }
            guard isRunning(generation: generation) else { break }
            await refresh(generation: generation)
        }
        finishLoop(generation: generation, id: id)
    }

    private func initializeNotifications(generation: UInt64, revision: UInt64) async {
        let enabled = await notifications.isEnabled()
        guard canPublishStartupNotificationOperation(
            generation: generation,
            revision: revision
        ) else {
            return
        }
        notificationsEnabled = enabled

        await notifications.requestAuthorization()
        guard canPublishStartupNotificationOperation(
            generation: generation,
            revision: revision
        ) else {
            return
        }
        let permission = await notifications.permissionState()
        guard canPublishStartupNotificationOperation(
            generation: generation,
            revision: revision
        ) else {
            return
        }
        notificationPermission = permission
    }

    private func loadCache(generation: UInt64) async {
        guard canMutate(generation: generation) else { return }
        guard let snapshot = await cache.load() else { return }
        guard canMutate(generation: generation) else { return }

        state = snapshot.isStale(at: now())
            ? .stale(snapshot, message: "缓存数据可能已过期")
            : .fresh(snapshot)
    }

    private func refresh(generation: UInt64) async {
        guard canMutate(generation: generation) else { return }
        if let refreshTask, refreshTask.generation == generation {
            await refreshTask.task.value
            return
        }

        let id = makeTaskID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation, id: id)
        }
        refreshTask = OwnedTask(id: id, generation: generation, task: task)
        await task.value
        if refreshTask?.id == id, refreshTask?.generation == generation {
            refreshTask = nil
        }
    }

    private func performRefresh(generation: UInt64, id: UInt64) async {
        guard canMutate(generation: generation) else { return }
        isRefreshing = true
        defer {
            if self.generation == generation, refreshTask?.id == id {
                isRefreshing = false
            }
        }

        do {
            let snapshot = try await reader.read()
            guard canMutate(generation: generation), !Task.isCancelled else { return }

            state = .fresh(snapshot)
            lastErrorMessage = nil

            var auxiliaryErrorMessage: String?
            do {
                try await cache.save(snapshot)
            } catch {
                auxiliaryErrorMessage = error.localizedDescription
            }

            guard canMutate(generation: generation), !Task.isCancelled else { return }
            await notifications.reconcile(snapshot: snapshot, now: now())
            guard canMutate(generation: generation), !Task.isCancelled else { return }
            lastErrorMessage = auxiliaryErrorMessage
        } catch {
            guard
                canMutate(generation: generation),
                !Task.isCancelled,
                !(error is CancellationError)
            else {
                return
            }

            let message = error.localizedDescription
            lastErrorMessage = message
            if let snapshot = state.snapshot {
                state = snapshot.isStale(at: now())
                    ? .stale(snapshot, message: message)
                    : .fresh(snapshot)
            } else {
                state = .unavailable(message: message)
            }
        }
    }

    private func canMutate(generation: UInt64) -> Bool {
        self.generation == generation && stopTask == nil
    }

    private func isRunning(generation: UInt64) -> Bool {
        isStarted && canMutate(generation: generation) && !Task.isCancelled
    }

    private func canPublishNotificationOperation(generation: UInt64, revision: UInt64) -> Bool {
        canMutate(generation: generation) && notificationOperationRevision == revision
    }

    private func canPublishStartupNotificationOperation(
        generation: UInt64,
        revision: UInt64
    ) -> Bool {
        isRunning(generation: generation)
            && notificationOperationRevision == revision
    }

    private func finishLoop(generation: UInt64, id: UInt64) {
        guard loopTask?.generation == generation, loopTask?.id == id else { return }
        loopTask = nil
        if self.generation == generation {
            isStarted = false
        }
    }

    private func finishStop(id: UInt64) {
        guard stopTask?.id == id else { return }
        isRefreshing = false
        refreshTask = nil
        loopTask = nil
        stopTask = nil
    }

    private func beginNotificationOperation() -> UInt64 {
        notificationOperationRevision &+= 1
        return notificationOperationRevision
    }

    private func makeTaskID() -> UInt64 {
        nextTaskID &+= 1
        return nextTaskID
    }
}
