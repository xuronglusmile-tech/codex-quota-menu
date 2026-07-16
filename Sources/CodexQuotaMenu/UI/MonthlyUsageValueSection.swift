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
                Text("本月 API 等价价值")
                Spacer()
                Text(value.rangeText).bold()
            }
            UsageValueTrack(presentation: value)
            HStack(spacing: 12) {
                Label("低估 \(value.lowerText)", systemImage: "square.fill")
                    .foregroundStyle(.green)
                Label("高估 \(value.upperText)", systemImage: "square.fill")
                    .foregroundStyle(.yellow)
            }
            .font(.caption2)
            Text(value.statusText)
                .font(.caption)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("本月 \(value.tokenText) · GPT-5.6 Sol")
                Text("API 等价估算，并非实际账单")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "本月 API 等价价值 \(value.rangeText)，\(value.statusText)，本月 \(value.tokenText)，并非实际账单"
        )
    }
}

private struct UsageValueTrack: View {
    let presentation: APIEquivalentValuePresentation

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let lowerWidth = width * CGFloat(presentation.lowerFraction)
                let upperWidth = width * CGFloat(presentation.upperFraction)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 9)
                        .offset(y: 11)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: lowerWidth, height: 9)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.green, .yellow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(upperWidth - lowerWidth, 0), height: 9)
                            .offset(x: lowerWidth)
                    }
                    .frame(width: width, height: 9, alignment: .leading)
                    .clipShape(Capsule())
                    .offset(y: 11)
                    marker(color: .red, height: 29)
                        .offset(x: width * CGFloat(presentation.plusFraction) - 1)
                    marker(color: .purple, height: 29)
                        .offset(x: width * CGFloat(presentation.proFraction) - 1)
                }
            }
            .frame(height: 31)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Text("$0").position(x: 6, y: 6)
                    Text("Plus $20").foregroundStyle(.red)
                        .position(x: max(26, width * CGFloat(presentation.plusFraction)), y: 6)
                    Text("Pro $200").foregroundStyle(.purple)
                        .position(x: width * CGFloat(presentation.proFraction), y: 6)
                    Text("$250").position(x: width - 14, y: 6)
                }
                .font(.system(size: 9))
            }
            .frame(height: 12)
        }
        .accessibilityHidden(true)
    }

    private func marker(color: Color, height: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: 2, height: height)
    }
}
