import AppKit

/// Where the notch is (or where a fake one goes) and how big the black shape grows.
/// The maths is pure so it can be tested; `forScreen(_:)` reads a real screen.
struct NotchMetrics: Equatable {
    /// The screen the notch lives on, in global AppKit coordinates.
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// False on Macs without a notch (or a closed lid): we draw a fake one.
    var hasNotch: Bool

    /// Size of one pixel of the character art, in points. Whole device pixels keep the art crisp:
    /// 2.5 pt only where there's a real notch (always Retina), 2 pt on a fake one (maybe a 1x display).
    var pixel: CGFloat { hasNotch ? 2.5 : 2 }
    /// Concave flare where the notch meets the top edge.
    var topRadius: CGFloat { 6 }
    /// Room on each side of the notch for characters to walk (a setting).
    var wingWidth: CGFloat = NotchMetrics.defaultWingWidth
    static let defaultWingWidth: CGFloat = 180
    /// The closed shape stays in the menu bar strip; only its wings grow.
    func shapeSize(expanded: Bool) -> CGSize {
        CGSize(width: notchWidth + 2 * topRadius + (expanded ? 2 * wingWidth : 0), height: notchHeight)
    }
    /// Gap under the walkers' feet in the closed notch; the short flag just fits above them.
    var floorInset: CGFloat { min(4, max(1, (notchHeight - Sprite.compactWaveRows * pixel) / 2)) }

    // Open panel (hover): a short stage for the walkers, a "Needs you" list, then a grid of the rest.
    static let openWidth: CGFloat = 640
    static let openPadding: CGFloat = 14
    static let openGap: CGFloat = 8
    static let sectionLabelHeight: CGFloat = 14
    static let waitingRowHeight: CGFloat = 52
    /// A permission prompt shows its full command and the answer buttons.
    static let askRowHeight: CGFloat = 92
    /// A finished turn with something to review: Claude's last words, the files, the tests, and actions.
    static let reviewRowHeight: CGFloat = 118
    static let tileHeight: CGFloat = 62
    static let emptyHeight: CGFloat = 52
    static let awayRowHeight: CGFloat = 22
    var openPixel: CGFloat { pixel }
    /// Just tall enough for a waving Claude: the cards are the point of the panel.
    var openStageHeight: CGFloat { Sprite.waveRows * openPixel + 6 }

    func openSize(_ layout: PanelLayout) -> CGSize {
        let width = max(Self.openWidth, shapeSize(expanded: true).width)
        var height = notchHeight + openStageHeight + Self.openGap
        if layout.isEmpty { height += Self.emptyHeight + Self.openGap }
        if layout.waiting > 0 {
            let rows = layout.rows.reduce(0, +)
            height += Self.sectionLabelHeight + Self.openGap + rows + CGFloat(layout.waiting - 1) * Self.openGap + Self.openGap
        }
        if layout.tileRows > 0 {
            height += Self.sectionLabelHeight + Self.openGap
                + CGFloat(layout.tileRows) * Self.tileHeight + CGFloat(layout.tileRows - 1) * Self.openGap + Self.openGap
        }
        if layout.away > 0 {
            height += Self.sectionLabelHeight + Self.openGap + Self.awayRowHeight + Self.openGap
        }
        return CGSize(width: width, height: height - Self.openGap + Self.openPadding)
    }

    /// The panel is fixed at the largest size; the shape animates inside it.
    var panelFrame: CGRect {
        let collapsed = shapeSize(expanded: true)
        let open = openSize(.largest)
        let size = CGSize(width: max(collapsed.width, open.width) + 40,
                          height: max(collapsed.height, open.height) + 20)
        return CGRect(x: screenFrame.midX - size.width / 2,
                      y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    static let fakeNotchWidth: CGFloat = 190

    static func make(screenFrame: CGRect, safeAreaTop: CGFloat,
                     leftArea: CGRect?, rightArea: CGRect?, visibleMaxY: CGFloat) -> NotchMetrics {
        if safeAreaTop > 0, let leftArea, let rightArea {
            return NotchMetrics(screenFrame: screenFrame,
                                notchWidth: rightArea.minX - leftArea.maxX,
                                notchHeight: safeAreaTop, hasNotch: true)
        }
        let menuBar = screenFrame.maxY - visibleMaxY
        return NotchMetrics(screenFrame: screenFrame, notchWidth: fakeNotchWidth,
                            notchHeight: menuBar > 0 ? menuBar : 24, hasNotch: false)
    }

    /// The screen the notch goes on: one with a real notch, otherwise the menu bar screen.
    @MainActor static var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    @MainActor static func forScreen(_ screen: NSScreen?, wingWidth: CGFloat = defaultWingWidth) -> NotchMetrics {
        var metrics = screen.map {
            make(screenFrame: $0.frame, safeAreaTop: $0.safeAreaInsets.top,
                 leftArea: $0.auxiliaryTopLeftArea, rightArea: $0.auxiliaryTopRightArea,
                 visibleMaxY: $0.visibleFrame.maxY)
        } ?? NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          notchWidth: fakeNotchWidth, notchHeight: 24, hasNotch: false)
        metrics.wingWidth = wingWidth
        return metrics
    }
}
