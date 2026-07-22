import AppKit
import SwiftUI

@MainActor
final class CodexQuotaMenuApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationCoordinator = ApplicationTerminationCoordinator(
        reply: { shouldTerminate in
            NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    )

    func configureTermination(cleanup: @escaping ApplicationTerminationCoordinator.Cleanup) {
        terminationCoordinator = ApplicationTerminationCoordinator(
            cleanup: cleanup,
            reply: { shouldTerminate in
                NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        terminationCoordinator.requestTermination()
    }
}

@main
@MainActor
struct CodexQuotaMenuApp: App {
    @NSApplicationDelegateAdaptor(CodexQuotaMenuApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var store: QuotaStore
    @StateObject private var launchAtLogin: LaunchAtLoginController

    init() {
        let store = QuotaStore(
            reader: ProductionQuotaReader(),
            cache: FileQuotaCache(),
            notifications: ExpiryNotificationScheduler()
        )
        let launchAtLogin = LaunchAtLoginController()
        _store = StateObject(wrappedValue: store)
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        applicationDelegate.configureTermination {
            await store.stop()
        }
        launchAtLogin.ensureDefaultEnabled()
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                store: store,
                launchAtLogin: launchAtLogin
            )
        } label: {
            MenuBarQuotaLabel(presentation: store.menuPresentation)
        }
        .menuBarExtraStyle(.window)
    }
}
