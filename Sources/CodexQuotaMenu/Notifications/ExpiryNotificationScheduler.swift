import Foundation
import UserNotifications

struct ExpiryNotificationPlan: Equatable, Sendable {
    let identifier: String
    let fireAt: Date
    let expiresAt: Date
}

enum ExpiryNotificationIdentifier {
    static let prefix = "codex-reset-"

    static func make(anonymousCreditKey: String) -> String? {
        guard isLowercaseSHA256Hex(anonymousCreditKey) else { return nil }
        return "\(prefix)\(anonymousCreditKey)"
    }

    static func isValid(_ identifier: String) -> Bool {
        guard identifier.hasPrefix(prefix) else { return false }
        return isLowercaseSHA256Hex(String(identifier.dropFirst(prefix.count)))
    }

    static func isOwned(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }

    private static func isLowercaseSHA256Hex(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

enum ExpiryNotificationPlanner {
    static let identifierPrefix = ExpiryNotificationIdentifier.prefix

    static func plans(for snapshot: QuotaSnapshot, now: Date) -> [ExpiryNotificationPlan] {
        var earliestExpirationByIdentifier: [String: Date] = [:]
        for credit in snapshot.resetCredits ?? [] {
            guard
                credit.status == .available,
                let expiresAt = credit.expiresAt,
                expiresAt > now,
                let identifier = ExpiryNotificationIdentifier.make(
                    anonymousCreditKey: credit.id
                )
            else {
                continue
            }

            // A conflicting duplicate is malformed input; the earliest expiry is the
            // safest canonical choice and makes the result independent of input order.
            if let existing = earliestExpirationByIdentifier[identifier], existing <= expiresAt {
                continue
            }
            earliestExpirationByIdentifier[identifier] = expiresAt
        }

        return earliestExpirationByIdentifier.map { identifier, expiresAt in
            let preferredFireAt = expiresAt.addingTimeInterval(-86_400)
            return ExpiryNotificationPlan(
                identifier: identifier,
                fireAt: preferredFireAt > now
                    ? preferredFireAt
                    : now.addingTimeInterval(1),
                expiresAt: expiresAt
            )
        }.sorted { lhs, rhs in
            if lhs.fireAt != rhs.fireAt { return lhs.fireAt < rhs.fireAt }
            return lhs.identifier < rhs.identifier
        }
    }
}

protocol ExpiryNotificationReconciling: Sendable {
    func requestAuthorization() async
    func reconcile(snapshot: QuotaSnapshot, now: Date) async
    func setEnabled(_ enabled: Bool) async
    func isEnabled() async -> Bool
    func permissionState() async -> NotificationPermissionState
}

enum NotificationPermissionState: Equatable, Sendable {
    case unknown
    case authorized
    case denied
}

struct ExpiryNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireAt: Date
}

protocol UserNotificationCenterGateway: Sendable {
    func permissionState() async throws -> NotificationPermissionState
    func requestAuthorization() async throws -> Bool
    func pendingRequestIdentifiers() async throws -> Set<String>
    func add(_ request: ExpiryNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async throws
}

actor SystemUserNotificationCenterGateway: UserNotificationCenterGateway {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    static func triggerDateComponents(for fireAt: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: fireAt
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return components
    }

    func permissionState() async throws -> NotificationPermissionState {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingRequestIdentifiers() async throws -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    func add(_ request: ExpiryNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Self.triggerDateComponents(for: request.fireAt),
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async throws {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

struct NotificationLedger {
    static let storageKey = "notifiedResetCreditKeys"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func identifiers() -> Set<String> {
        Set(
            (defaults.stringArray(forKey: Self.storageKey) ?? [])
                .filter(Self.isPersistableIdentifier)
        )
    }

    func replace(with identifiers: Set<String>) {
        defaults.set(
            identifiers.filter(Self.isPersistableIdentifier).sorted(),
            forKey: Self.storageKey
        )
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private static func isPersistableIdentifier(_ identifier: String) -> Bool {
        ExpiryNotificationIdentifier.isValid(identifier)
    }
}

private struct MutationQueueDepthWaiter {
    let minimumDepth: Int
    let continuation: CheckedContinuation<Void, Never>
}

actor ExpiryNotificationScheduler: ExpiryNotificationReconciling {
    private static let enabledKey = "expiryNotificationsEnabled"

    private let gateway: any UserNotificationCenterGateway
    private let defaults: UserDefaults
    private let ledger: NotificationLedger
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationQueueDepthWaiters: [MutationQueueDepthWaiter] = []

    init(
        gateway: any UserNotificationCenterGateway = SystemUserNotificationCenterGateway(),
        defaults: UserDefaults = .standard
    ) {
        self.gateway = gateway
        self.defaults = defaults
        self.ledger = NotificationLedger(defaults: defaults)
    }

    func isEnabled() async -> Bool {
        isEnabledUnlocked()
    }

    func setEnabled(_ enabled: Bool) async {
        await acquireMutationOperation()
        defer { releaseMutationOperation() }
        await setEnabledUnlocked(enabled)
    }

    func requestAuthorization() async {
        await acquireMutationOperation()
        defer { releaseMutationOperation() }
        await requestAuthorizationUnlocked()
    }

    func permissionState() async -> NotificationPermissionState {
        await permissionStateUnlocked()
    }

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {
        await acquireMutationOperation()
        defer { releaseMutationOperation() }
        await reconcileUnlocked(snapshot: snapshot, now: now)
    }

    func waitUntilMutationQueueDepthForTesting(_ minimumDepth: Int) async {
        precondition(minimumDepth >= 0)
        guard mutationWaiters.count < minimumDepth else { return }
        await withCheckedContinuation { continuation in
            mutationQueueDepthWaiters.append(
                MutationQueueDepthWaiter(
                    minimumDepth: minimumDepth,
                    continuation: continuation
                )
            )
        }
    }

    private func isEnabledUnlocked() -> Bool {
        defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
    }

    private func setEnabledUnlocked(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard !enabled else {
            await requestAuthorizationUnlocked()
            return
        }

        if let pending = try? await gateway.pendingRequestIdentifiers() {
            let owned = pending
                .filter(ExpiryNotificationIdentifier.isOwned)
                .sorted()
            if !owned.isEmpty {
                try? await gateway.removePendingRequests(withIdentifiers: owned)
            }
        }
        ledger.clear()
    }

    private func requestAuthorizationUnlocked() async {
        guard isEnabledUnlocked() else { return }
        _ = try? await gateway.requestAuthorization()
    }

    private func permissionStateUnlocked() async -> NotificationPermissionState {
        (try? await gateway.permissionState()) ?? .unknown
    }

    private func reconcileUnlocked(snapshot: QuotaSnapshot, now: Date) async {
        guard isEnabledUnlocked() else { return }
        let plans = ExpiryNotificationPlanner.plans(for: snapshot, now: now)
        let desired = Set(plans.map(\.identifier))
        guard let pending = try? await gateway.pendingRequestIdentifiers() else { return }
        guard isEnabledUnlocked() else { return }
        let obsolete = pending
            .filter {
                ExpiryNotificationIdentifier.isOwned($0) && !desired.contains($0)
            }
            .sorted()
        if !obsolete.isEmpty {
            try? await gateway.removePendingRequests(withIdentifiers: obsolete)
        }

        var notified = ledger.identifiers().intersection(desired)
        guard await permissionStateUnlocked() == .authorized else {
            ledger.replace(with: notified)
            return
        }
        guard isEnabledUnlocked() else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        for plan in plans {
            guard isEnabledUnlocked() else { return }
            guard !pending.contains(plan.identifier), !notified.contains(plan.identifier) else {
                continue
            }

            let request = ExpiryNotificationRequest(
                identifier: plan.identifier,
                title: "Codex 重置额度即将到期",
                body: "一份重置额度将在 \(formatter.string(from: plan.expiresAt)) 到期。",
                fireAt: plan.fireAt
            )
            do {
                try await gateway.add(request)
                notified.insert(plan.identifier)
            } catch {
                continue
            }
        }

        ledger.replace(with: notified)
    }

    private func acquireMutationOperation() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
            resumeSatisfiedMutationQueueDepthWaiters()
        }
    }

    private func releaseMutationOperation() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private func resumeSatisfiedMutationQueueDepthWaiters() {
        var remaining: [MutationQueueDepthWaiter] = []
        for waiter in mutationQueueDepthWaiters {
            if mutationWaiters.count >= waiter.minimumDepth {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        mutationQueueDepthWaiters = remaining
    }
}
