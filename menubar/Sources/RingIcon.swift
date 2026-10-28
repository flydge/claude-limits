import AppKit

// Draws the menu bar icons: two rings with the percentage inside, and for the system
// item each ring after a small memory or disk symbol.

enum RingIcon {
    static let ringSize: CGFloat = 20
    static let gap: CGFloat = 4
    static let lineWidth: CGFloat = 1.8

    static func image(_ left: RingState, _ right: RingState) -> NSImage {
        let size = NSSize(width: ringSize * 2 + gap, height: ringSize)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(left, in: NSRect(x: 0, y: 0, width: ringSize, height: ringSize))
            draw(right, in: NSRect(x: ringSize + gap, y: 0, width: ringSize, height: ringSize))
            return true
        }
        image.isTemplate = false
        return image
    }

    static let symbolWidth: CGFloat = 16

    static func systemImage(memory: RingState, disk: RingState) -> NSImage {
        let pair = symbolWidth + ringSize
        let size = NSSize(width: pair * 2 + gap, height: ringSize)
        let image = NSImage(size: size, flipped: false) { _ in
            drawSymbol("memorychip", in: NSRect(x: 0, y: 0, width: symbolWidth, height: ringSize))
            draw(memory, in: NSRect(x: symbolWidth, y: 0, width: ringSize, height: ringSize))
            drawSymbol("internaldrive", in: NSRect(x: pair + gap, y: 0, width: symbolWidth, height: ringSize))
            draw(disk, in: NSRect(x: pair + gap + symbolWidth, y: 0, width: ringSize, height: ringSize))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The attention bell with the number of waiting sessions: orange while one is blocked,
    /// green when they are only done.
    static func bellImage(_ bell: Bell) -> NSImage {
        let color: NSColor = bell.isBlocking ? .systemOrange : .systemGreen
        let text = NSAttributedString(string: "\(bell.count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: color,
        ])
        let textSize = text.size()
        let size = NSSize(width: symbolWidth + 2 + ceil(textSize.width), height: ringSize)
        let image = NSImage(size: size, flipped: false) { _ in
            drawSymbol("bell.fill", in: NSRect(x: 0, y: 0, width: symbolWidth, height: ringSize), color: color, pointSize: 13)
            text.draw(at: NSPoint(x: symbolWidth + 2, y: (ringSize - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor = .labelColor,
                                   pointSize: CGFloat = 11) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    static func color(for state: RingState) -> NSColor {
        switch state {
        case .normal(_, let level, _): return color(for: level)
        case .exhausted: return .systemRed
        case .stale, .empty: return .secondaryLabelColor
        }
    }

    static func color(for level: Level) -> NSColor {
        switch level {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .danger: return .systemRed
        }
    }

    private static func draw(_ state: RingState, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (rect.width - lineWidth) / 2 - 0.5

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()

        let fraction: Double
        let label: String
        switch state {
        case .normal(let f, _, let l), .stale(let f, let l): (fraction, label) = (f, l)
        case .exhausted: (fraction, label) = (1, "!")
        case .empty: (fraction, label) = (0, "–")
        }

        if fraction > 0 {
            let arc = NSBezierPath()
            if fraction >= 1 {
                arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            } else {
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
                arc.lineCapStyle = .round
            }
            arc.lineWidth = lineWidth
            color(for: state).setStroke()
            arc.stroke()
        }

        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .kern: -0.2,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
