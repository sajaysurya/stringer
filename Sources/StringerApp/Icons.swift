import AppKit
import StringerCore

enum Icons {
    static let orange = NSColor(srgbRed: 1.0, green: 0.48, blue: 0.0, alpha: 1)

    /// Idle: a striped square of six equal rounded bars, as a template image
    /// so it follows light and dark menu bars.
    static let idle: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let side: CGFloat = 14, x0: CGFloat = 2, y0: CGFloat = 2
            let bars = 6
            let pitch = side / CGFloat(bars)
            let w = pitch * 0.62
            NSColor.black.setFill()
            for i in 0..<bars {
                let r = NSRect(x: x0 + CGFloat(i) * pitch + (pitch - w) / 2, y: y0, width: w, height: side)
                NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// Recording: an orange square in two rows — mic on top, system audio
    /// below — each a moving waveform above −50 dBFS and a flat line below,
    /// with the timer beside it in orange. One non-template image: the menu
    /// bar recolours template images and label text, so colour is otherwise
    /// impossible.
    static func recording(mic: Float, system: Float, phase: Double, timer: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: orange]
        let text = NSAttributedString(string: timer, attributes: attrs)
        let tw = ceil(text.size().width)
        let size = NSSize(width: 18 + 4 + tw, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let box = NSRect(x: 1, y: 1, width: 16, height: 16)
            orange.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
            // Divider between the rows.
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSRect(x: box.minX + 2, y: box.midY - 0.25, width: box.width - 4, height: 0.5).fill()
            wave(in: NSRect(x: box.minX + 2, y: box.midY + 0.5, width: box.width - 4, height: box.height / 2 - 2), level: mic, phase: phase)
            wave(in: NSRect(x: box.minX + 2, y: box.minY + 1.5, width: box.width - 4, height: box.height / 2 - 2), level: system, phase: phase * 1.3 + 1.7)
            text.draw(at: NSPoint(x: 22, y: (18 - text.size().height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }

    static func wave(in r: NSRect, level: Float, phase: Double) {
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        let mid = r.midY
        // Loudness on a log scale: −50 dBFS → 0, 0 dBFS → full height.
        let db = Double(Signal.dbfs(max(level, 1e-6)))
        let amp = level < Signal.silencePeak ? 0 : max(0.25, min(1, (db + 50) / 40)) * Double(r.height / 2)
        let steps = 24
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            let env = sin(Double.pi * x)  // taper at the edges
            let y = amp * env * (0.7 * sin(2 * .pi * (x * 2.2) + phase) + 0.3 * sin(2 * .pi * (x * 5.3) - phase * 1.7))
            let p = NSPoint(x: r.minX + CGFloat(x) * r.width, y: mid + CGFloat(y))
            i == 0 ? path.move(to: p) : path.line(to: p)
        }
        NSColor.white.setStroke()
        path.stroke()
    }
}
