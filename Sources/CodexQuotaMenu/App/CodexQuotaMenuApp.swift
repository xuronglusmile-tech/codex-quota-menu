import SwiftUI

@main
struct CodexQuotaMenuApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("正在准备额度读取…")
                .padding()
        } label: {
            Label("— · —", systemImage: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
