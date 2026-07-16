import SwiftUI

struct MonthlyUsageValueSection: View {
    let usage: MonthlyUsage

    private var presentation: APIEquivalentValuePresentation {
        APIEquivalentValuePresentation(usage: usage)
    }

    var body: some View {
        let value = presentation
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sol API 假设场景")
                Spacer()
                Text(value.rangeText).bold()
            }
            UsageValueTrack(presentation: value)
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    "缓存较多情景 \(value.cachedHeavyText)",
                    systemImage: "square.fill"
                )
                .foregroundStyle(.green)
                Label(
                    "输出较多情景 \(value.outputHeavyText)",
                    systemImage: "square.fill"
                )
                .foregroundStyle(.yellow)
            }
            .font(.caption2)
            Text("固定构成：80/15/5 · 40/40/20")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("本月 \(value.tokenText) · GPT-5.6 Sol 标准 API 价格")
                Text("情景估算，并非实际账单或订阅价值")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sol API 假设场景，缓存较多情景 \(value.cachedHeavyText)，输出较多情景 \(value.outputHeavyText)，本月 \(value.tokenText)，固定构成 80/15/5 与 40/40/20，情景估算，并非实际账单或订阅价值"
        )
    }
}

private struct UsageValueTrack: View {
    let presentation: APIEquivalentValuePresentation

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let cachedHeavyWidth = width * CGFloat(presentation.cachedHeavyFraction)
                let outputHeavyWidth = width * CGFloat(presentation.outputHeavyFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: cachedHeavyWidth)
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(outputHeavyWidth - cachedHeavyWidth, 0))
                        .offset(x: cachedHeavyWidth)
                }
                .clipShape(Capsule())
            }
            .frame(height: 9)
            HStack {
                Text("$0")
                Spacer()
                Text(presentation.trackMidpointText)
                Spacer()
                Text(presentation.trackMaximumText)
            }
            .font(.system(size: 9))
        }
        .accessibilityHidden(true)
    }
}
