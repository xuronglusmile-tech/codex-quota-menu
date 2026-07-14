import Combine
import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

protocol LoginItemServicing: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

final class MainAppLoginItemService: LoginItemServicing {
    private let service = SMAppService.mainApp

    var state: LoginItemState {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    private static let approvalMessage = "请在系统设置 → 通用 → 登录项中批准。"
    private static let unavailableMessage =
        "登录项不可用，请在系统设置 → 通用 → 登录项中检查后重试。"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var message: String?

    private let service: any LoginItemServicing
    private let defaults: UserDefaults
    private let configuredKey = "launchAtLoginConfigured"

    init(
        service: any LoginItemServicing = MainAppLoginItemService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        self.isEnabled = false
        self.message = nil
        refresh()
    }

    func ensureDefaultEnabled() {
        guard !defaults.bool(forKey: configuredKey) else { return }

        let currentState = service.state
        if currentState == .enabled || currentState == .requiresApproval {
            synchronize(with: currentState)
            defaults.set(true, forKey: configuredKey)
            return
        }

        do {
            try service.register()
            let updatedState = service.state
            synchronize(with: updatedState)
            if updatedState == .enabled || updatedState == .requiresApproval {
                defaults.set(true, forKey: configuredKey)
            }
        } catch {
            let updatedState = service.state
            synchronize(with: updatedState, error: error)
            if updatedState == .enabled || updatedState == .requiresApproval {
                defaults.set(true, forKey: configuredKey)
            }
        }
    }

    func refresh() {
        synchronize(with: service.state)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(true, forKey: configuredKey)

        let currentState = service.state
        if enabled, currentState == .enabled || currentState == .requiresApproval {
            synchronize(with: currentState)
            return
        }
        if !enabled, currentState == .disabled {
            synchronize(with: currentState)
            return
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            synchronize(with: service.state)
        } catch {
            synchronize(with: service.state, error: error)
        }
    }

    private func synchronize(with state: LoginItemState, error: (any Error)? = nil) {
        isEnabled = state == .enabled

        switch state {
        case .requiresApproval:
            message = Self.approvalMessage
        case .unavailable:
            message = error.map(Self.operationErrorMessage(for:))
                ?? Self.unavailableMessage
        case .enabled, .disabled:
            message = error.map(Self.operationErrorMessage(for:))
        }
    }

    private static func operationErrorMessage(for error: any Error) -> String {
        "无法更新登录时启动设置：\(error.localizedDescription)。" +
            "请在系统设置 → 通用 → 登录项中检查后重试。"
    }
}
