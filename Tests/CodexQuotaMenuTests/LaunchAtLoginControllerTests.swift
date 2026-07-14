import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite(.serialized)
@MainActor
struct LaunchAtLoginControllerTests {
    private static let approvalMessage = "请在系统设置 → 通用 → 登录项中批准。"
    private static let unavailableMessage =
        "登录项不可用，请在系统设置 → 通用 → 登录项中检查后重试。"
    private static let operationErrorMessage =
        "无法更新登录时启动设置：测试操作失败。请在系统设置 → 通用 → 登录项中检查后重试。"

    @Test
    func testFirstRunRegistersByDefaultOnlyOnce() {
        let service = FakeLoginItemService()
        let controller = LaunchAtLoginController(
            service: service,
            defaults: Self.defaults()
        )

        controller.ensureDefaultEnabled()
        controller.ensureDefaultEnabled()

        #expect(service.registerCount == 1)
        #expect(controller.isEnabled)
    }

    @Test
    func testUserCanDisableLaunchAtLogin() {
        let service = FakeLoginItemService(initial: .enabled)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: Self.defaults()
        )

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(!controller.isEnabled)
    }

    @Test
    func testInitializationReflectsEveryServiceStateAndMessage() {
        let enabled = LaunchAtLoginController(
            service: FakeLoginItemService(initial: .enabled),
            defaults: Self.defaults()
        )
        let disabled = LaunchAtLoginController(
            service: FakeLoginItemService(initial: .disabled),
            defaults: Self.defaults()
        )
        let requiresApproval = LaunchAtLoginController(
            service: FakeLoginItemService(initial: .requiresApproval),
            defaults: Self.defaults()
        )
        let unavailable = LaunchAtLoginController(
            service: FakeLoginItemService(initial: .unavailable),
            defaults: Self.defaults()
        )

        #expect(enabled.isEnabled)
        #expect(enabled.message == nil)
        #expect(!disabled.isEnabled)
        #expect(disabled.message == nil)
        #expect(!requiresApproval.isEnabled)
        #expect(requiresApproval.message == Self.approvalMessage)
        #expect(!unavailable.isEnabled)
        #expect(unavailable.message == Self.unavailableMessage)
    }

    @Test
    func testRefreshResyncsExternalStateWithoutServiceOperations() {
        let service = FakeLoginItemService(initial: .enabled)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: Self.defaults()
        )

        service.state = .requiresApproval
        controller.refresh()

        #expect(!controller.isEnabled)
        #expect(controller.message == Self.approvalMessage)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)

        service.state = .enabled
        controller.refresh()

        #expect(controller.isEnabled)
        #expect(controller.message == nil)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test
    func testDefaultRegistrationThatRequiresApprovalIsConfiguredOnce() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(
            initial: .disabled,
            stateAfterRegister: .requiresApproval
        )
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.ensureDefaultEnabled()
        controller.ensureDefaultEnabled()

        #expect(service.registerCount == 1)
        #expect(!controller.isEnabled)
        #expect(controller.message == Self.approvalMessage)

        let replacementService = FakeLoginItemService(initial: .disabled)
        let replacement = LaunchAtLoginController(
            service: replacementService,
            defaults: defaults
        )
        replacement.ensureDefaultEnabled()
        #expect(replacementService.registerCount == 0)
    }

    @Test
    func testExistingApprovalRequirementSatisfiesDefaultWithoutReregistering() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(initial: .requiresApproval)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.ensureDefaultEnabled()

        #expect(service.registerCount == 0)
        #expect(controller.message == Self.approvalMessage)

        let replacementService = FakeLoginItemService(initial: .disabled)
        let replacement = LaunchAtLoginController(
            service: replacementService,
            defaults: defaults
        )
        replacement.ensureDefaultEnabled()
        #expect(replacementService.registerCount == 0)
    }

    @Test
    func testTransientDefaultRegistrationFailureRemainsRetryable() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(
            registerError: .operationFailed
        )
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.ensureDefaultEnabled()

        #expect(service.registerCount == 1)
        #expect(!controller.isEnabled)
        #expect(controller.message == Self.operationErrorMessage)

        service.registerError = nil
        controller.ensureDefaultEnabled()

        #expect(service.registerCount == 2)
        #expect(controller.isEnabled)
        #expect(controller.message == nil)
    }

    @Test
    func testUnresolvedDefaultStateRemainsRetryableWithoutThrownError() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(
            initial: .disabled,
            stateAfterRegister: .unavailable
        )
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.ensureDefaultEnabled()
        controller.ensureDefaultEnabled()

        #expect(service.registerCount == 2)
        #expect(!controller.isEnabled)
        #expect(controller.message == Self.unavailableMessage)
    }

    @Test
    func testAlreadySatisfiedExplicitTogglesAreIdempotentAndPersisted() {
        let enabledDefaults = Self.defaults()
        let enabledService = FakeLoginItemService(initial: .enabled)
        let enabledController = LaunchAtLoginController(
            service: enabledService,
            defaults: enabledDefaults
        )
        enabledController.setEnabled(true)
        #expect(enabledService.registerCount == 0)
        #expect(enabledController.isEnabled)

        let approvalDefaults = Self.defaults()
        let approvalService = FakeLoginItemService(initial: .requiresApproval)
        let approvalController = LaunchAtLoginController(
            service: approvalService,
            defaults: approvalDefaults
        )
        approvalController.setEnabled(true)
        #expect(approvalService.registerCount == 0)
        #expect(approvalController.message == Self.approvalMessage)

        let disabledDefaults = Self.defaults()
        let disabledService = FakeLoginItemService(initial: .disabled)
        let disabledController = LaunchAtLoginController(
            service: disabledService,
            defaults: disabledDefaults
        )
        disabledController.setEnabled(false)
        #expect(disabledService.unregisterCount == 0)
        #expect(!disabledController.isEnabled)

        for defaults in [enabledDefaults, approvalDefaults, disabledDefaults] {
            let replacementService = FakeLoginItemService(initial: .disabled)
            let replacement = LaunchAtLoginController(
                service: replacementService,
                defaults: defaults
            )
            replacement.ensureDefaultEnabled()
            #expect(replacementService.registerCount == 0)
        }
    }

    @Test
    func testExplicitDisablePersistsAcrossControllerInstances() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(initial: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.setEnabled(false)

        let replacement = LaunchAtLoginController(service: service, defaults: defaults)
        replacement.ensureDefaultEnabled()

        #expect(service.unregisterCount == 1)
        #expect(service.registerCount == 0)
        #expect(!replacement.isEnabled)
    }

    @Test
    func testExplicitEnableErrorPersistsOverrideAndShowsActionableError() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(registerError: .operationFailed)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.setEnabled(true)

        #expect(service.registerCount == 1)
        #expect(!controller.isEnabled)
        #expect(controller.message == Self.operationErrorMessage)

        let replacementService = FakeLoginItemService(initial: .disabled)
        let replacement = LaunchAtLoginController(
            service: replacementService,
            defaults: defaults
        )
        replacement.ensureDefaultEnabled()
        #expect(replacementService.registerCount == 0)
    }

    @Test
    func testExplicitDisableErrorPersistsOverrideAndResyncsEnabledState() {
        let defaults = Self.defaults()
        let service = FakeLoginItemService(
            initial: .enabled,
            unregisterError: .operationFailed
        )
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(controller.isEnabled)
        #expect(controller.message == Self.operationErrorMessage)

        let replacementService = FakeLoginItemService(initial: .disabled)
        let replacement = LaunchAtLoginController(
            service: replacementService,
            defaults: defaults
        )
        replacement.ensureDefaultEnabled()
        #expect(replacementService.registerCount == 0)
    }

    private static func defaults() -> UserDefaults {
        let suiteName = "LaunchAtLoginControllerTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}

private final class FakeLoginItemService: LoginItemServicing {
    var state: LoginItemState
    var registerError: TestLoginItemError?
    var unregisterError: TestLoginItemError?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let stateAfterRegister: LoginItemState
    private let stateAfterUnregister: LoginItemState

    init(
        initial: LoginItemState = .disabled,
        stateAfterRegister: LoginItemState = .enabled,
        stateAfterUnregister: LoginItemState = .disabled,
        registerError: TestLoginItemError? = nil,
        unregisterError: TestLoginItemError? = nil
    ) {
        state = initial
        self.stateAfterRegister = stateAfterRegister
        self.stateAfterUnregister = stateAfterUnregister
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        state = stateAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        state = stateAfterUnregister
    }
}

private enum TestLoginItemError: LocalizedError {
    case operationFailed

    var errorDescription: String? {
        "测试操作失败"
    }
}
