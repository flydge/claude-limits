import AppKit

// Renders every ring state, the system item and the bell, in light and dark appearance, to a PNG so the icon
// can be checked without the menu bar:  ClaudeLimits --preview out.png

enum Preview {
    static func render(to path: String) -> Bool {
        let rows: [(RingState, RingState)] = [
            (.normal(fraction: 0.42, level: .ok, label: "42"), .normal(fraction: 0.18, level: .ok, label: "18")),
            (.normal(fraction: 0.62, level: .warn, label: "62"), .normal(fraction: 0.88, level: .danger, label: "88")),
            (.exhausted, .stale(fraction: 0.3, label: "30")),
            (.empty, .empty),
        ]
        let images: [() -> NSImage] = rows.map { row in { RingIcon.image(row.0, row.1) } } + [
            { RingIcon.systemImage(memory: .normal(fraction: 0.55, level: .ok, label: "55"),
                                   disk: .normal(fraction: 0.7, level: .warn, label: "70")) },
            { RingIcon.systemImage(memory: .normal(fraction: 0.93, level: .danger, label: "93"),
                                   disk: .normal(fraction: 0.98, level: .danger, label: "98")) },
            { RingIcon.systemImage(memory: .empty, disk: .empty) },
            { RingIcon.bellImage(Bell(count: 2, isBlocking: true)) },
            { RingIcon.bellImage(Bell(count: 1, isBlocking: false)) },
        ]
        let scale: CGFloat = 4
        let pad: CGFloat = 6
        let icon = NSSize(width: (RingIcon.symbolWidth + RingIcon.ringSize) * 2 + RingIcon.gap,
                          height: RingIcon.ringSize)
        let columnWidth = icon.width + pad * 2
        let width = columnWidth * 2
        let height = (icon.height + pad) * CGFloat(images.count) + pad
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (column, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let x = CGFloat(column) * columnWidth
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: x, y: 0, width: columnWidth, height: height).fill()
                for (index, makeImage) in images.enumerated() {
                    let y = height - CGFloat(index + 1) * (icon.height + pad)
                    makeImage().draw(
                        at: NSPoint(x: x + pad, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
