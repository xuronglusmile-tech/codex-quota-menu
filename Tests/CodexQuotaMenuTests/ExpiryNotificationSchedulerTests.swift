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
    func testPreferredFireDateLessThanOneSecondInFutureIsPreservedExactly() {
        let now = Date(timeIntervalSince1970: 1_000)
        let preferredFireAt = now.addingTimeInterval(0.25)
        let credit = Self.credit(
            id: String(repeating: "d", count: 64),
            expiresAt: preferredFireAt.addingTimeInterval(86_400)
        )

        let plans = ExpiryNotificationPlanner.plans(for: Self.snapshot([credit]), now: now)

        #expect(plans.map(\.fireAt) == [preferredFireAt])
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
    func testPlannerChoosesEarliestConflictingDuplicateIndependentOfInputOrder() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let creditID = String(repeating: "5", count: 64)
        let earlier = Self.credit(id: creditID, expiresAt: now.addingTimeInterval(100_000))
        let later = Self.credit(id: creditID, expiresAt: now.addingTimeInterval(200_000))

        let forward = ExpiryNotificationPlanner.plans(
            for: Self.snapshot([later, earlier]),
            now: now
        )
        let reversed = ExpiryNotificationPlanner.plans(
            for: Self.snapshot([earlier, later]),
            now: now
        )

        #expect(forward == reversed)
        #expect(try #require(forward.first).expiresAt == earlier.expiresAt)
    }

    @Test
    func testPlannerSortsByFireDateThenIdentifier() {
        let now = Date(timeIntervalSince1970: 1_000)
        let laterID = String(repeating: "7", count: 64)
        let sameFireHighID = String(repeating: "8", count: 64)
        let sameFireLowID = String(repeating: "6", count: 64)
        let sameExpiration = now.addingTimeInterval(100_000)
        let credits = [
            Self.credit(id: laterID, expiresAt: now.addingTimeInterval(200_000)),
            Self.credit(id: sameFireHighID, expiresAt: sameExpiration),
            Self.credit(id: sameFireLowID, expiresAt: sameExpiration)
        ]

        let plans = ExpiryNotificationPlanner.plans(for: Self.snapshot(credits), now: now)

        #expect(plans.map(\.identifier) == [
            "codex-reset-\(sameFireLowID)",
            "codex-reset-\(sameFireHighID)",
            "codex-reset-\(laterID)"
        ])
    }

    @Test
    func testPlannerRejectsMalformedRawAndUppercaseCreditIDs() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = now.addingTimeInterval(100_000)
        let invalidIDs = [
            "raw-backend-id",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64)
        ]
        let credits = invalidIDs.map { Self.credit(id: $0, expiresAt: future) }

        #expect(ExpiryNotificationPlanner.plans(for: Self.snapshot(credits), now: now).isEmpty)
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
    func testAuthorizedReconcilePreservesAbsoluteFireDateAcrossSuspension() async throws {
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            cooperativeDelayCount: 10
        )
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
        #expect(request.fireAt == Self.now.addingTimeInterval(86_400))
        #expect(request.title == "Codex 重置额度即将到期")
        #expect(!request.body.isEmpty)
    }

    @Test
    func testCalendarTriggerComponentsRoundTripAbsoluteSubsecondDateInUTC() throws {
        let fireAt = Date(timeIntervalSince1970: 1_000.125)

        let components = SystemUserNotificationCenterGateway.triggerDateComponents(for: fireAt)
        let calendar = try #require(components.calendar)
        let reconstructed = try #require(calendar.date(from: components))

        #expect(components.timeZone?.secondsFromGMT() == 0)
        #expect(components.nanosecond != nil)
        #expect(abs(reconstructed.timeIntervalSince(fireAt)) < 0.000_000_001)
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

    @Test
    func testConcurrentReconcilesSerializeWithoutLosingLedgerEntries() async {
        let defaults = Self.defaults()
        let firstKey = String(repeating: "1", count: 64)
        let secondKey = String(repeating: "2", count: 64)
        let firstID = "codex-reset-\(firstKey)"
        let secondID = "codex-reset-\(secondKey)"
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            suspendFirstPermissionState: true
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        let first = Task {
            await scheduler.reconcile(snapshot: Self.futureSnapshot(id: firstKey), now: Self.now)
        }
        await gateway.waitUntilFirstPermissionStateIsSuspended()
        let second = Task {
            let expiration = Self.now.addingTimeInterval(172_800)
            await scheduler.reconcile(
                snapshot: Self.snapshot([
                    Self.credit(id: firstKey, expiresAt: expiration),
                    Self.credit(id: secondKey, expiresAt: expiration)
                ]),
                now: Self.now
            )
        }
        await scheduler.waitUntilMutationQueueDepthForTesting(1)

        #expect(await gateway.permissionStateCallCount == 1)
        await gateway.resumeFirstPermissionState()
        await first.value
        await second.value

        #expect(await gateway.addedRequests.map(\.identifier) == [firstID, secondID])
        #expect(NotificationLedger(defaults: defaults).identifiers() == [firstID, secondID])
    }

    @Test
    func testDisableQueuedDuringReconcileWinsBeforeNewerReconcile() async {
        let defaults = Self.defaults()
        let firstKey = String(repeating: "3", count: 64)
        let newerKey = String(repeating: "4", count: 64)
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            suspendFirstPermissionState: true
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        let first = Task {
            await scheduler.reconcile(snapshot: Self.futureSnapshot(id: firstKey), now: Self.now)
        }
        await gateway.waitUntilFirstPermissionStateIsSuspended()
        let disable = Task { await scheduler.setEnabled(false) }
        await scheduler.waitUntilMutationQueueDepthForTesting(1)
        let newer = Task {
            await scheduler.reconcile(snapshot: Self.futureSnapshot(id: newerKey), now: Self.now)
        }
        await scheduler.waitUntilMutationQueueDepthForTesting(2)

        await gateway.resumeFirstPermissionState()
        await first.value
        await disable.value
        await newer.value

        #expect(!(await scheduler.isEnabled()))
        #expect(NotificationLedger(defaults: defaults).identifiers().isEmpty)
        #expect(await gateway.pendingIdentifiers.allSatisfy {
            !$0.hasPrefix(ExpiryNotificationPlanner.identifierPrefix)
        })
        #expect(await gateway.addedRequests.map(\.identifier) == ["codex-reset-\(firstKey)"])
    }

    @Test
    func testPendingReadFailureIsSwallowedWithoutSchedulingOrLedgerMutation() async {
        let defaults = Self.defaults()
        let existingID = "codex-reset-\(String(repeating: "5", count: 64))"
        NotificationLedger(defaults: defaults).replace(with: [existingID])
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            pendingReadFails: true
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        await scheduler.reconcile(snapshot: Self.futureSnapshot(), now: Self.now)

        #expect(await gateway.addAttempts.isEmpty)
        #expect(NotificationLedger(defaults: defaults).identifiers() == [existingID])
    }

    @Test
    func testReconcileRemovalFailureIsSwallowedAndDesiredAddStillPersists() async {
        let defaults = Self.defaults()
        let obsoleteID = "codex-reset-\(String(repeating: "6", count: 64))"
        let desiredKey = String(repeating: "7", count: 64)
        let desiredID = "codex-reset-\(desiredKey)"
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            pendingIdentifiers: [obsoleteID],
            removalFails: true
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        await scheduler.reconcile(
            snapshot: Self.futureSnapshot(id: desiredKey),
            now: Self.now
        )

        #expect(await gateway.removedIdentifierBatches == [[obsoleteID]])
        #expect(await gateway.pendingIdentifiers == [obsoleteID, desiredID])
        #expect(await gateway.addedRequests.map(\.identifier) == [desiredID])
        #expect(NotificationLedger(defaults: defaults).identifiers() == [desiredID])
    }

    @Test
    func testDisableRemovalFailureStillClearsLedgerAndLeavesPreferenceDisabled() async {
        let defaults = Self.defaults()
        let identifier = "codex-reset-\(String(repeating: "8", count: 64))"
        NotificationLedger(defaults: defaults).replace(with: [identifier])
        let gateway = FakeUserNotificationCenterGateway(
            permissionState: .authorized,
            pendingIdentifiers: [identifier],
            removalFails: true
        )
        let scheduler = ExpiryNotificationScheduler(gateway: gateway, defaults: defaults)

        await scheduler.setEnabled(false)

        #expect(!(await scheduler.isEnabled()))
        #expect(NotificationLedger(defaults: defaults).identifiers().isEmpty)
        #expect(await gateway.removedIdentifierBatches == [[identifier]])
        #expect(await gateway.pendingIdentifiers == [identifier])
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
    private let cooperativeDelayCount: Int
    private let pendingReadFails: Bool
    private let removalFails: Bool
    private var shouldSuspendNextPermissionState: Bool
    private var suspendedPermissionState: CheckedContinuation<Void, Never>?
    private var permissionStateSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var pendingIdentifiers: Set<String>
    private(set) var authorizationRequestCount = 0
    private(set) var permissionStateCallCount = 0
    private(set) var addAttempts: [ExpiryNotificationRequest] = []
    private(set) var addedRequests: [ExpiryNotificationRequest] = []
    private(set) var removedIdentifierBatches: [[String]] = []

    init(
        permissionState: NotificationPermissionState = .unknown,
        permissionStateFails: Bool = false,
        authorizationRequestFails: Bool = false,
        addFailures: Set<String> = [],
        cooperativeDelayCount: Int = 0,
        pendingIdentifiers: Set<String> = [],
        pendingReadFails: Bool = false,
        removalFails: Bool = false,
        suspendFirstPermissionState: Bool = false
    ) {
        self.configuredPermissionState = permissionState
        self.permissionStateFails = permissionStateFails
        self.authorizationRequestFails = authorizationRequestFails
        self.addFailures = addFailures
        self.cooperativeDelayCount = cooperativeDelayCount
        self.pendingIdentifiers = pendingIdentifiers
        self.pendingReadFails = pendingReadFails
        self.removalFails = removalFails
        self.shouldSuspendNextPermissionState = suspendFirstPermissionState
    }

    func permissionState() async throws -> NotificationPermissionState {
        permissionStateCallCount += 1
        if shouldSuspendNextPermissionState {
            shouldSuspendNextPermissionState = false
            await withCheckedContinuation { continuation in
                suspendedPermissionState = continuation
                let waiters = permissionStateSuspensionWaiters
                permissionStateSuspensionWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        await cooperativeDelay()
        guard !permissionStateFails else { throw FakeNotificationError.failed }
        return configuredPermissionState
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        guard !authorizationRequestFails else { throw FakeNotificationError.failed }
        return true
    }

    func pendingRequestIdentifiers() async throws -> Set<String> {
        await cooperativeDelay()
        guard !pendingReadFails else { throw FakeNotificationError.failed }
        return pendingIdentifiers
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
        guard !removalFails else { throw FakeNotificationError.failed }
        pendingIdentifiers.subtract(sorted)
    }

    func waitUntilFirstPermissionStateIsSuspended() async {
        guard suspendedPermissionState == nil else { return }
        await withCheckedContinuation { continuation in
            permissionStateSuspensionWaiters.append(continuation)
        }
    }

    func resumeFirstPermissionState() {
        let continuation = suspendedPermissionState
        suspendedPermissionState = nil
        continuation?.resume()
    }

    private func cooperativeDelay() async {
        for _ in 0..<cooperativeDelayCount {
            await Task<Never, Never>.yield()
        }
    }
}
