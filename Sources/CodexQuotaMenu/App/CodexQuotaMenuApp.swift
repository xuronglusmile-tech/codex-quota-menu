import SwiftUI

@main
@MainActor
struct CodexQuotaMenuApp: App {
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
            Label(
                store.menuTitle,
                systemImage: "gauge.with.dots.needle.50percent"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
