import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct ExpiryNotificationSchedulerTests {
    @Test
    func testPlansExactlyTwentyFourHoursBeforeExpiration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credit = Self.credit(
            id: String(repeating: "a", count: 64),
            expiresAt: now.addingTimeInterval(172_800)
        )

        let plans = ExpiryNotificationPlanner.plans(for: Self.snapshot([credit]), now: now)

        #expect(plans.map(\.fireAt) == [now.addingTimeInterval(86_400)])
    }

    @Test
    func testInsideWindowPlansForOneSecondFromNow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credit = Self.credit(
            id: String(repeating: "b", count: 64),
            expiresAt: now.addingTimeInterval(3_600)
        )

        let plans = ExpiryNotificationPlanner.plans(for: Self.snapshot([credit]), now: now)

        #expect(plans.map(\.fireAt) == [now.addingTimeInterval(1)])
    }

    @Test
    func testExactTwentyFourHourBoundaryPlansForOneSecondFromNow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credit = Self.credit(
            id: String(repeating: "c", count: 64),
            expiresAt: now.addingTimeInterval(86_400)
        )

        let plans = ExpiryNotificationPlanner.plans(for: Self.snapshot([credit]), now: now)

        #expect(plans.map(\.fireAt) == [now.addingTimeInterval(1)])
    }

    @Test
    func testSkipsCreditsExpiringNowOrEarlier() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credits = [
            Self.credit(id: String(repeating: "d", count: 64), expiresAt: now),
            Self.credit(id: String(repeating: "e", count: 64), expiresAt: now.addingTimeInterval(-1))
        ]

        #expect(ExpiryNotificationPlanner.plans(for: Self.snapshot(credits), now: now).isEmpty)
    }

    @Test
    func testSkipsEveryNonavailableStatusAndNonexpiringCredits() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = now.addingTimeInterval(100)
        let credits = [
            Self.credit(id: String(repeating: "f", count: 64), status: .redeeming, expiresAt: future),
            Self.credit(id: String(repeating: "0", count: 64), status: .redeemed, expiresAt: future),
            Self.credit(id: String(repeating: "1", count: 64), status: .unknown, expiresAt: future),
            Self.credit(id: String(repeating: "2", count: 64), expiresAt: nil)
        ]

        #expect(ExpiryNotificationPlanner.plans(for: Self.snapshot(credits), now: now).isEmpty)
    }

    @Test
    func testPlannerProducesDeterministicStableIdentifier() {
        let now = Date(timeIntervalSince1970: 1_000)
        let creditID = String(repeating: "3", count: 64)
        let snapshot = Self.snapshot([
            Self.credit(id: creditID, expiresAt: now.addingTimeInterval(172_800))
        ])
        let expected = ["codex-reset-\(creditID)"]

        #expect(ExpiryNotificationPlanner.plans(for: snapshot, now: now).map(\.identifier) == expected)
        #expect(ExpiryNotificationPlanner.plans(for: snapshot, now: now).map(\.identifier) == expected)
    }

    @Test
    func testPlannerDeduplicatesDuplicateCreditInput() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credit = Self.credit(
            id: String(repeating: "4", count: 64),
            expiresAt: now.addingTimeInterval(172_800)
        )

        let plans = ExpiryNotificationPlanner.plans(for: Self.snapshot([credit, credit]), now: now)

        #expect(plans.count == 1)
    }

    @Test
    func testNotificationPreferenceDefaultsToEnabled() async {
        let scheduler = ExpiryNotificationScheduler(
            gateway: FakeUserNotificationCenterGateway(),
            defaults: Self.defaults()
        )

        #expect(await scheduler.isEnabled())
    }

    @Test(arguments: [
        NotificationPermissionState.authorized,
        NotificationPermissionState.unknown,
        NotificationPermissionState.denied
    ])
    func testPermissionStateExposesGatewayState(_ state: NotificationPermissionState) async {
        let scheduler = ExpiryNotificationScheduler(
            gateway: FakeUserNotificationCenterGateway(permissionState: state),
            defaults: Self.defaults()
        )

        #expect(await scheduler.permissionState() == state)
    }

    @Test
    func testPermissionStateFailureBecomesUnknownAndDoesNotSchedule() async {
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            permissionStateFails: true
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())

        #expect(await scheduler.permissionState() == .unknown)
        await scheduler.reconcile(snapshot: Self.futureSnapshot(), now: Self.now)

        #expect(await gateway.addAttempts.isEmpty)
    }

    @Test
    func testAuthorizedReconcileSchedulesExactRequest() async throws {
        let gateway = FakeUserNotificationCenterGateway(permissionState: .authorized)
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())
        let creditID = String(repeating: "5", count: 64)
        let credit = Self.credit(
            id: creditID,
            expiresAt: Self.now.addingTimeInterval(172_800)
        )

        await scheduler.reconcile(snapshot: Self.snapshot([credit]), now: Self.now)

        let request = try #require(await gateway.addedRequests.first)
        #expect(await gateway.addedRequests.count == 1)
        #expect(request.identifier == "codex-reset-\(creditID)")
        #expect(request.timeInterval == 86_400)
        #expect(request.title == "Codex 重置额度即将到期")
        #expect(!request.body.isEmpty)
    }

    @Test(arguments: [NotificationPermissionState.unknown, .denied])
    func testReconcileDoesNotScheduleWithoutAuthorizedPermission(
        _ state: NotificationPermissionState
    ) async {
        let gateway = FakeUserNotificationCenterGateway(permissionState: state)
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())

        await scheduler.reconcile(snapshot: Self.futureSnapshot(), now: Self.now)

        #expect(await gateway.addAttempts.isEmpty)
    }

    @Test
    func testDeniedPermissionStillAllowsObsoleteOwnedRequestCleanup() async {
        let obsoleteID = "codex-reset-\(String(repeating: "f", count: 64))"
        let unrelatedID = "another-app-notification"
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .denied,
            pendingIdentifiers: [obsoleteID, unrelatedID]
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())

        await scheduler.reconcile(snapshot: Self.snapshot([]), now: Self.now)

        #expect(await gateway.removedIdentifierBatches == [[obsoleteID]])
        #expect(await gateway.pendingIdentifiers == [unrelatedID])
        #expect(await gateway.addAttempts.isEmpty)
    }

    @Test
    func testRequestAuthorizationSuccessIsContainedWithinNotificationLayer() async {
        let gateway = FakeUserNotificationCenterGateway()
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())

        await scheduler.requestAuthorization()

        #expect(await gateway.authorizationRequestCount == 1)
    }

    @Test
    func testRequestAuthorizationFailureIsSwallowed() async {
        let gateway = FakeUserNotificationCenterGateway(authorizationRequestFails: true)
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())

        await scheduler.requestAuthorization()

        #expect(await gateway.authorizationRequestCount == 1)
    }

    @Test
    func testFailedAddDoesNotEnterPersistentLedger() async {
        let defaults = Self.defaults()
        let identifier = "codex-reset-\(String(repeating: "6", count: 64))"
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            addFailures: [identifier]
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        await scheduler.reconcile(snapshot: Self.futureSnapshot(id: String(repeating: "6", count: 64)), now: Self.now)

        #expect(await gateway.addAttempts.map(\.identifier) == [identifier])
        #expect(NotificationLedger(defaults: defaults).identifiers().isEmpty)
    }

    @Test
    func testExistingPendingRequestAndLedgerBothPreventDuplicateAdds() async {
        let defaults = Self.defaults()
        let pendingID = "codex-reset-\(String(repeating: "7", count: 64))"
        let ledgerID = "codex-reset-\(String(repeating: "8", count: 64))"
        NotificationLedger(defaults: defaults).replace(with: [ledgerID])
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            pendingIdentifiers: [pendingID]
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)
        let snapshot = Self.snapshot([
            Self.credit(id: String(repeating: "7", count: 64), expiresAt: Self.now.addingTimeInterval(172_800)),
            Self.credit(id: String(repeating: "8", count: 64), expiresAt: Self.now.addingTimeInterval(172_800))
        ])

        await scheduler.reconcile(snapshot: snapshot, now: Self.now)

        #expect(await gateway.addAttempts.isEmpty)
        #expect(NotificationLedger(defaults: defaults).identifiers() == [ledgerID])
    }

    @Test
    func testReconcileRemovesOnlyObsoleteRequestsWithApplicationPrefix() async {
        let desiredID = "codex-reset-\(String(repeating: "9", count: 64))"
        let obsoleteID = "codex-reset-\(String(repeating: "a", count: 64))"
        let malformedPrefixedID = "codex-reset-not-an-anonymous-key"
        let unrelatedID = "another-app-notification"
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            pendingIdentifiers: [desiredID, obsoleteID, malformedPrefixedID, unrelatedID]
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())

        await scheduler.reconcile(
            snapshot: Self.futureSnapshot(id: String(repeating: "9", count: 64)),
            now: Self.now
        )

        #expect(await gateway.removedIdentifierBatches == [[malformedPrefixedID, obsoleteID].sorted()])
        #expect(await gateway.pendingIdentifiers == [desiredID, unrelatedID])
        #expect(await gateway.addAttempts.isEmpty)
    }

    @Test
    func testDisablingRemovesPrefixedPendingRequestsAndClearsLedger() async {
        let defaults = Self.defaults()
        let identifier = "codex-reset-\(String(repeating: "b", count: 64))"
        NotificationLedger(defaults: defaults).replace(with: [identifier])
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            pendingIdentifiers: [identifier, "another-app-notification"]
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        await scheduler.setEnabled(false)
        await scheduler.reconcile(snapshot: Self.futureSnapshot(), now: Self.now)

        #expect(!(await scheduler.isEnabled()))
        #expect(NotificationLedger(defaults: defaults).identifiers().isEmpty)
        #expect(await gateway.pendingIdentifiers == ["another-app-notification"])
        #expect(await gateway.addAttempts.isEmpty)
    }

    @Test
    func testReenablingRequestsAuthorization() async {
        let gateway = FakeUserNotificationCenterGateway()
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: Self.defaults())
        await scheduler.setEnabled(false)

        await scheduler.setEnabled(true)

        #expect(await scheduler.isEnabled())
        #expect(await gateway.authorizationRequestCount == 1)
    }

    @Test
    func testSuccessfulAddLedgerPersistsAcrossSchedulerInstances() async {
        let defaults = Self.defaults()
        let firstGateway = FakeUserNotificationCenterGateway(permissionState: .authorized)
        let firstScheduler = ExpiryNotificationScheduler(gateway: firstGateway, defaults: defaults)
        let snapshot = Self.futureSnapshot(id: String(repeating: "c", count: 64))

        await firstScheduler.reconcile(snapshot: snapshot, now: Self.now)

        #expect(await firstGateway.addedRequests.count == 1)
        let secondGateway = FakeUserNotificationCenterGateway(permissionState: .authorized)
        let secondScheduler = ExpiryNotificationScheduler(gateway: secondGateway, defaults: defaults)
        await secondScheduler.reconcile(snapshot: snapshot, now: Self.now)
        #expect(await secondGateway.addAttempts.isEmpty)
    }

    @Test
    func testLedgerPersistsOnlyPrefixedLowercaseSHA256Keys() {
        let defaults = Self.defaults()
        let valid = "codex-reset-\(String(repeating: "d", count: 64))"
        let uppercase = "codex-reset-\(String(repeating: "A", count: 64))"
        let ledger = NotificationLedger(defaults: defaults)

        ledger.replace(with: [valid, uppercase, "raw-backend-id", "codex-reset-short"])

        #expect(ledger.identifiers() == [valid])
        #expect(defaults.stringArray(forKey: NotificationLedger.storageKey) == [valid])
    }

    private static let now = Date(timeIntervalSince1970: 1_000)

    private static func credit(
        id: String,
        status: ResetCreditStatus = .available,
        expiresAt: Date?
    ) -> ResetCredit {
        ResetCredit(
            id: id,
            status: status,
            grantedAt: now,
            expiresAt: expiresAt,
            title: nil,
            detail: nil
        )
    }

    private static func snapshot(_ credits: [ResetCredit]) -> QuotaSnapshot {
        QuotaSnapshot(
            windows: [
                QuotaWindow(
                    id: "w",
                    label: "额度",
                    usedPercent: 1,
                    durationMinutes: nil,
                    resetsAt: nil
                )
            ],
            availableResetCount: credits.count,
            resetCredits: credits,
            fetchedAt: .distantPast
        )
    }

    private static func futureSnapshot(
        id: String = String(repeating: "e", count: 64)
    ) -> QuotaSnapshot {
        snapshot([credit(id: id, expiresAt: now.addingTimeInterval(172_800))])
    }

    private static func defaults() -> UserDefaults {
        let suiteName = "ExpiryNotificationSchedulerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private enum FakeNotificationError: Error {
    case failed
}

private actor FakeUserNotificationCenterGateway: UserNotificationCenterGateway {
    private let configuredPermissionState: NotificationPermissionState
    private let permissionStateFails: Bool
    private let authorizationRequestFails: Bool
    private let addFailures: Set<String>

    private(set) var pendingIdentifiers: Set<String>
    private(set) var authorizationRequestCount = 0
    private(set) var addAttempts: [ExpiryNotificationRequest] = []
    private(set) var addedRequests: [ExpiryNotificationRequest] = []
    private(set) var removedIdentifierBatches: [[String]] = []

    init(
        permissionState: NotificationPermissionState = .unknown,
        permissionStateFails: Bool = false,
        authorizationRequestFails: Bool = false,
        addFailures: Set<String> = [],
        pendingIdentifiers: Set<String> = []
    ) {
        self.configuredPermissionState = permissionState
        self.permissionStateFails = permissionStateFails
        self.authorizationRequestFails = authorizationRequestFails
        self.addFailures = addFailures
        self.pendingIdentifiers = pendingIdentifiers
    }

    func permissionState() async throws -> NotificationPermissionState {
        guard !permissionStateFails else { throw FakeNotificationError.failed }
        return configuredPermissionState
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        guard !authorizationRequestFails else { throw FakeNotificationError.failed }
        return true
    }

    func pendingRequestIdentifiers() async throws -> Set<String> {
        pendingIdentifiers
    }

    func add(_ request: ExpiryNotificationRequest) async throws {
        addAttempts.append(request)
        guard !addFailures.contains(request.identifier) else {
            throw FakeNotificationError.failed
        }
        addedRequests.append(request)
        pendingIdentifiers.insert(request.identifier)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async throws {
        let sorted = identifiers.sorted()
        removedIdentifierBatches.append(sorted)
        pendingIdentifiers.subtract(sorted)
    }
}
