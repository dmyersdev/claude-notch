import AppKit

/// The menu bar icon: a tiny pixel Claude standing under a notch, drawn as a template image so it
/// follows the menu bar's light or dark look. When a session needs you, it holds up a flag.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 16)

    /// Filled cells on an 18 x 16 grid of 1 pt squares, top-left origin. Eyes are the gaps.
    static func cells(flag: Bool) -> [(Int, Int)] {
        var cells: [(Int, Int)] = []
        func rect(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>) {
            for column in x { for row in y { cells.append((column, row)) } }
        }
        // The notch: a bar along the top with rounded lower corners.
        rect(3...14, 0...1)
        rect(4...13, 2...2)
        // Head and torso, with two eyes left out.
        rect(5...12, 5...9)
        let eyes = [(7, 6), (7, 7), (10, 6), (10, 7)]
        cells.removeAll { cell in eyes.contains { $0 == cell } }
        // Arms; with a flag, the right one holds the pole instead.
        rect(3...4, 8...8)
        if !flag { rect(13...14, 8...8) }
        // Four legs.
        for x in [5, 7, 10, 12] { rect(x...x, 10...11) }
        if flag {
            rect(14...14, 3...8)
            rect(15...17, 3...5)
        }
        return cells
    }

    static func image(flag: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            // Nudged down so the figure sits centred against the menu bar text.
            for (x, y) in cells(flag: flag) {
                NSRect(x: CGFloat(x), y: CGFloat(y) + 2, width: 1, height: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = flag ? "Claude Notch: a session needs you" : "Claude Notch"
        return image
    }
}
