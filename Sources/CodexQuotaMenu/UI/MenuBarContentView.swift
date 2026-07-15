import AppKit
import SwiftUI

enum ResetCreditUrgency {
    static let thresholdSeconds: TimeInterval = 86_400

    static func isUrgent(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 && remaining <= thresholdSeconds
    }

    static func statusText(expiresAt: Date?, now: Date) -> String? {
        isUrgent(expiresAt: expiresAt, now: now) ? "即将到期" : nil
    }
}

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    private let now: @Sendable () -> Date

    init(
        store: QuotaStore,
        launchAtLogin: LaunchAtLoginController,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quotaContent
            statusContent
            settingsControls
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    private var header: some View {
        HStack {
            Text("Codex 额度")
                .font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .accessibilityLabel("刷新额度")
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if let snapshot = store.state.snapshot {
            ForEach(snapshot.windows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.label)
                        Spacer()
                        Text("\(window.remainingPercent)%")
                            .bold()
                    }
                    ProgressView(
                        value: Double(window.remainingPercent),
                        total: 100
                    )
                    .tint(quotaTint(for: window))
                    if let resetsAt = window.resetsAt {
                        Text(
                            "重置：\(resetsAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            if let monthlyUsage = snapshot.monthlyUsage {
                MonthlyUsageValueSection(usage: monthlyUsage)
            } else {
                Text("本月使用数据暂不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("本月 API 等价价值暂不可用")
            }
            Divider()
            HStack {
                Text("可用重置次数")
                Spacer()
                Text("\(snapshot.availableResetCount)")
                    .font(.title2)
                    .bold()
            }
            resetCredits(snapshot.resetCredits)

            Text(
                "最后更新：\(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text(store.lastErrorMessage ?? "正在读取额度…")
                .foregroundStyle(.secondary)
            if case .unavailable = store.state {
                Button("重新检测") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
            }
        }
    }

    private func quotaTint(for window: QuotaWindow) -> Color {
        switch QuotaProgressPresentation.band(
            remainingPercent: window.remainingPercent,
            durationMinutes: window.durationMinutes
        ) {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case nil: return .accentColor
        }
    }

    @ViewBuilder
    private func resetCredits(_ credits: [ResetCredit]?) -> some View {
        if let credits {
            ForEach(Array(credits.enumerated()), id: \.element.id) { item in
                resetCreditRow(item.element, position: item.offset + 1)
            }
        } else {
            Text("到期详情暂不可用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetCreditRow(_ credit: ResetCredit, position: Int) -> some View {
        let urgentStatus = ResetCreditUrgency.statusText(
            expiresAt: credit.expiresAt,
            now: now()
        )
        let expiration = credit.expiresAt?.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? "不过期"

        return HStack(alignment: .top) {
            Text(ResetCreditRowPresentation.ordinalLabel(position: position))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("到期：\(expiration)")
                .foregroundStyle(
                    urgentStatus == nil ? Color.secondary : Color.orange
                )
                if let urgentStatus {
                    Label(
                        urgentStatus,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var statusContent: some View {
        if case .stale(_, let message) = store.state {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if let message = store.lastErrorMessage,
                  store.state.snapshot != nil {
            Text(message)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("登录时启动", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            Toggle("到期通知", isOn: Binding(
                get: { store.notificationsEnabled },
                set: { enabled in
                    Task { await store.setNotificationsEnabled(enabled) }
                }
            ))
            if store.notificationsEnabled && store.notificationPermission == .denied {
                Text("通知权限未启用；额度显示不受影响。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = launchAtLogin.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("打开 ChatGPT") {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/Applications/ChatGPT.app")
                )
            }
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
