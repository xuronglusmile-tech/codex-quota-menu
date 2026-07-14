import Foundation
import UserNotifications

struct ExpiryNotificationPlan: Equatable, Sendable {
    let identifier: String
    let fireAt: Date
    let expiresAt: Date
}

enum ExpiryNotificationPlanner {
    static let identifierPrefix = "codex-reset-"

    static func plans(for snapshot: QuotaSnapshot, now: Date) -> [ExpiryNotificationPlan] {
        var plannedIdentifiers = Set<String>()

        return (snapshot.resetCredits ?? []).compactMap { credit in
            guard
                credit.status == .available,
                let expiresAt = credit.expiresAt,
                expiresAt > now
            else {
                return nil
            }

            let identifier = "\(identifierPrefix)\(credit.id)"
            guard plannedIdentifiers.insert(identifier).inserted else { return nil }

            return ExpiryNotificationPlan(
                identifier: identifier,
                fireAt: max(
                    expiresAt.addingTimeInterval(-86_400),
                    now.addingTimeInterval(1)
                ),
                expiresAt: expiresAt
            )
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
    let timeInterval: TimeInterval
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
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(request.timeInterval, 1),
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
        guard identifier.hasPrefix(ExpiryNotificationPlanner.identifierPrefix) else {
            return false
        }
        let digest = identifier.dropFirst(ExpiryNotificationPlanner.identifierPrefix.count)
        guard digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

actor ExpiryNotificationScheduler: ExpiryNotificationReconciling {
    private static let enabledKey = "expiryNotificationsEnabled"

    private let gateway: any UserNotificationCenterGateway
    private let defaults: UserDefaults
    private let ledger: NotificationLedger

    init(
        gateway: any UserNotificationCenterGateway = SystemUserNotificationCenterGateway(),
        defaults: UserDefaults = .standard
    ) {
        self.gateway = gateway
        self.defaults = defaults
        self.ledger = NotificationLedger(defaults: defaults)
    }

    func isEnabled() async -> Bool {
        defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard !enabled else {
            await requestAuthorization()
            return
        }

        if let pending = try? await gateway.pendingRequestIdentifiers() {
            let owned = pending
                .filter { $0.hasPrefix(ExpiryNotificationPlanner.identifierPrefix) }
                .sorted()
            if !owned.isEmpty {
                try? await gateway.removePendingRequests(withIdentifiers: owned)
            }
        }
        ledger.clear()
    }

    func requestAuthorization() async {
        guard await isEnabled() else { return }
        _ = try? await gateway.requestAuthorization()
    }

    func permissionState() async -> NotificationPermissionState {
        (try? await gateway.permissionState()) ?? .unknown
    }

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {
        guard await isEnabled() else { return }
        let plans = ExpiryNotificationPlanner.plans(for: snapshot, now: now)
        let desired = Set(plans.map(\.identifier))
        guard let pending = try? await gateway.pendingRequestIdentifiers() else { return }
        let obsolete = pending
            .filter {
                $0.hasPrefix(ExpiryNotificationPlanner.identifierPrefix)
                    && !desired.contains($0)
            }
            .sorted()
        if !obsolete.isEmpty {
            try? await gateway.removePendingRequests(withIdentifiers: obsolete)
        }

        var notified = ledger.identifiers().intersection(desired)
        guard await permissionState() == .authorized else {
            ledger.replace(with: notified)
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        for plan in plans {
            guard !pending.contains(plan.identifier), !notified.contains(plan.identifier) else {
                continue
            }

            let request = ExpiryNotificationRequest(
                identifier: plan.identifier,
                title: "Codex 重置额度即将到期",
                body: "一份重置额度将在 \(formatter.string(from: plan.expiresAt)) 到期。",
                timeInterval: max(plan.fireAt.timeIntervalSince(now), 1)
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
}
