import SwiftUI

@main
@MainActor
struct CodexQuotaMenuApp: App {
    @StateObject private var store: QuotaStore

    init() {
        let store = QuotaStore(
            reader: ProductionQuotaReader(),
            cache: FileQuotaCache(),
            notifications: ExpiryNotificationScheduler()
        )
        _store = StateObject(wrappedValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            Label(
                store.menuTitle,
                systemImage: "gauge.with.dots.needle.50percent"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
