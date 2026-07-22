import SwiftUI

struct MenuBarQuotaLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        HStack(spacing: 4) {
            Text(presentation.text)
                .monospacedDigit()

            MenuBarQuotaPill(
                fillFraction: presentation.fillFraction,
                band: presentation.band
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private struct MenuBarQuotaPill: View {
    let fillFraction: Double
    let band: QuotaProgressBand?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1)

            GeometryReader { proxy in
                if fillFraction > 0 {
                    Capsule(style: .continuous)
                        .fill(fillColor)
                        .frame(width: proxy.size.width * fillFraction)
                }
            }
            .padding(2)
        }
        .frame(width: 22, height: 10)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch band {
        case .normal:
            return Color.green
        case .warning:
            return Color.yellow
        case .critical:
            return Color.red
        case nil:
            return Color.clear
        }
    }
}
