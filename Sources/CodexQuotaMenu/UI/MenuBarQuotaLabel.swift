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
    private let fillWidth: CGFloat = 18

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.clear)

            if fillFraction > 0 {
                Capsule(style: .continuous)
                    .fill(fillColor)
                    .frame(width: fillWidth * fillFraction, height: 6)
                    .padding(.leading, 2)
            }

            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1)
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
