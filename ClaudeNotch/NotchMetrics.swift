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

    // Open panel (hover): a stage for the walkers above a grid of agent cards.
    static let openWidth: CGFloat = 620
    static let openPadding: CGFloat = 14
    static let openGap: CGFloat = 8
    static let cardHeight: CGFloat = 56
    static let cardColumns = 3
    static let maxCardRows = 2
    var openPixel: CGFloat { pixel }
    var openStageHeight: CGFloat { Sprite.waveRows * openPixel + 14 }

    static func cardRows(agentCount: Int) -> Int {
        min(maxCardRows, max(1, (agentCount + cardColumns - 1) / cardColumns))
    }

    func openSize(agentCount: Int) -> CGSize {
        let rows = CGFloat(Self.cardRows(agentCount: agentCount))
        let cards = rows * Self.cardHeight + (rows - 1) * Self.openGap
        let width = max(Self.openWidth, shapeSize(expanded: true).width)
        return CGSize(width: width,
                      height: notchHeight + openStageHeight + Self.openGap + cards + Self.openPadding)
    }

    /// The panel is fixed at the largest size; the shape animates inside it.
    var panelFrame: CGRect {
        let collapsed = shapeSize(expanded: true)
        let open = openSize(agentCount: Self.cardColumns * Self.maxCardRows)
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
