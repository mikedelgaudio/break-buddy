import AppKit

/// Draws the menu-bar label (symbol + countdown) into a template image. The countdown sits in a
/// fixed-width, right-aligned slot with monospaced digits, so the status item doesn't change
/// width as the numbers tick: SwiftUI's MenuBarExtra label ignores most font modifiers, so this
/// can't be done reliably with Text.
enum MenuBarIcon {
    static let height: CGFloat = 18
    private static let gap: CGFloat = 4
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    /// Widest two-digit readings; one-digit values ("9m", "5s") pad into the same slot.
    private static let slotSamples = ["00m", "00s"]

    static func image(symbol: String, text: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let slot = text.isEmpty ? 0 : (slotSamples + [text]).map { width(of: $0) }.max() ?? 0
        let spacing = text.isEmpty ? 0 : gap
        let size = NSSize(width: ceil(glyph.size.width + spacing + slot), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            if !text.isEmpty {
                let textSize = (text as NSString).size(withAttributes: attributes)
                let origin = NSPoint(x: size.width - textSize.width, y: (height - textSize.height) / 2)
                (text as NSString).draw(at: origin, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text.isEmpty ? "Break Buddy" : "Break Buddy, \(text)"
        return image
    }

    private static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }
}
