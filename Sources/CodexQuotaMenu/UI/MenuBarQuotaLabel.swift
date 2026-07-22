import AppKit
import SwiftUI

struct MenuBarQuotaLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        Image(nsImage: MenuBarQuotaStatusImage.make(presentation))
            .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private enum MenuBarQuotaStatusImage {
    static func make(_ presentation: MenuBarPresentation) -> NSImage {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let text = NSString(string: presentation.text)
        let textSize = text.size(withAttributes: textAttributes)
        let imageSize = NSSize(width: max(54, textSize.width + 22), height: 18)
        let image = NSImage(size: imageSize)
        image.isTemplate = false
        image.lockFocus()
        defer { image.unlockFocus() }

        let textRect = NSRect(
            x: 0,
            y: (imageSize.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: textAttributes)

        let pillRect = NSRect(
            x: textSize.width + 5,
            y: (imageSize.height - 9) / 2,
            width: 17,
            height: 9
        )
        let pillPath = NSBezierPath(
            roundedRect: pillRect,
            xRadius: pillRect.height / 2,
            yRadius: pillRect.height / 2
        )
        NSColor.white.withAlphaComponent(0.25).setFill()
        pillPath.fill()

        if presentation.fillFraction > 0 {
            let inset = 1.0
            let fillRect = NSRect(
                x: pillRect.minX + inset,
                y: pillRect.minY + inset,
                width: max(1, (pillRect.width - inset * 2) * presentation.fillFraction),
                height: pillRect.height - inset * 2
            )
            let fillPath = NSBezierPath(
                roundedRect: fillRect,
                xRadius: fillRect.height / 2,
                yRadius: fillRect.height / 2
            )
            fillColor(for: presentation.band).setFill()
            fillPath.fill()
        }

        NSColor.white.withAlphaComponent(0.7).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        return image
    }

    private static func fillColor(for band: QuotaProgressBand?) -> NSColor {
        switch band {
        case .normal:
            return NSColor.systemGreen
        case .warning:
            return NSColor.systemYellow
        case .critical:
            return NSColor.systemRed
        case nil:
            return NSColor.secondaryLabelColor
        }
    }
}
