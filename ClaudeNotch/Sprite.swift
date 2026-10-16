import SwiftUI

/// The little Claude, drawn as pixel art straight into a Canvas.
/// Grid is 12 columns by 7 rows; (0,0) is the top left of the body, feet on row 6.
enum Sprite {
    enum Facing { case left, right, front }

    enum Pose {
        case walk(Facing, step: Int)
        case stand(Facing)
        /// `compact` keeps the flag low enough to fit in the menu bar strip; `flagLeft` holds it in the left hand.
        /// A square flag means blocked on you; a `pennant` (tapering) means finished. Shape, not just colour.
        case wave(frame: Int, compact: Bool = false, flagLeft: Bool = false, color: Color = Sprite.flag, pennant: Bool = false)
        /// Hand up towards a friend on that side; `frame` 1 is the slap.
        case greet(Facing, frame: Int)
    }

    /// Something held or floating beside the character. `frame` animates it.
    enum Prop: Equatable {
        case book, pencil, magnifier
        case hammer(frame: Int)
        /// Asleep or stuck.
        case snooze(frame: Int)
        /// Just finished its turn.
        case sparkle(frame: Int)
    }

    static let columns = 12
    static let bodyRows: CGFloat = 7
    /// Body plus flag pole above it.
    static let waveRows: CGFloat = 15
    /// Body plus the short flag used in the closed notch.
    static let compactWaveRows: CGFloat = 10

    static let body = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let eye = Color.black
    static let pole = Color(white: 0.85)
    /// Blocked on a permission prompt.
    static let flag = Color(red: 1.0, green: 0.27, blue: 0.23)
    /// Finished; the user's turn when they're ready.
    static let turnFlag = Color(red: 0.36, green: 0.82, blue: 0.52)

    static func flagColor(for need: Need) -> Color { need == .permission ? flag : turnFlag }
    static func wave(for need: Need, frame: Int, compact: Bool, flagLeft: Bool) -> Pose {
        .wave(frame: frame, compact: compact, flagLeft: flagLeft, color: flagColor(for: need), pennant: need == .yourTurn)
    }

    /// Draws the sprite with its feet centred on `foot`. `lift` raises it that many art pixels (a hop).
    static func draw(_ pose: Pose, in context: GraphicsContext, foot: CGPoint, pixel: CGFloat,
                     prop: Prop? = nil, lift: Int = 0, pack: Load = .light) {
        let origin = CGPoint(x: (foot.x - CGFloat(columns) * pixel / 2).rounded(),
                             y: (foot.y - bodyRows * pixel).rounded() - CGFloat(lift) * pixel)
        func fill(_ x: Int, _ y: Int, _ color: Color) {
            let rect = CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel,
                              width: pixel, height: pixel)
            context.fill(Path(rect), with: .color(color))
        }

        let facing: Facing
        var raisedArm = false
        var flagLeft = false
        var stepFrame = 0
        switch pose {
        case .walk(let f, let step): facing = f; stepFrame = step
        case .stand(let f): facing = f
        case .wave(_, _, let left, _, _): facing = .front; raisedArm = true; flagLeft = left
        case .greet(let f, _): facing = f; raisedArm = true; flagLeft = f == .left
        }

        if pack != .light { drawPack(pack, facing: facing, fill: fill) }

        // Head and torso.
        for y in 0...4 { for x in 2...9 { fill(x, y, body) } }
        // Arms: both out to the side, unless one holds the flag.
        fill(1, 3, body); fill(10, 3, body)
        if !raisedArm || flagLeft { fill(11, 3, body) }
        if !raisedArm || !flagLeft { fill(0, 3, body) }
        // Eyes look where it walks.
        let eyes: [Int] = switch facing {
        case .left: [3, 6]
        case .right: [5, 8]
        case .front: [4, 7]
        }
        let asleep = if case .snooze = prop { true } else { false }
        for x in eyes {
            // Closed eyes when dozing: just the lower half.
            if !asleep { fill(x, 1, eye) }
            fill(x, 2, eye)
        }
        // Four legs; on the second step frame two of them lift.
        for x in [2, 4, 7, 9] {
            fill(x, 5, body)
            let lifted = stepFrame == 1 && (x == 2 || x == 7)
            if !lifted { fill(x, 6, body) }
        }

        if let prop { drawProp(prop, facing: facing, fill: fill) }

        if case .greet(let side, let frame) = pose {
            // Arm up and out towards the friend; on the slap, a little burst between them.
            let out = side == .left ? -1 : 1, hand = side == .left ? 0 : 11
            fill(hand, 2, body)
            fill(hand + out, frame == 1 ? 2 : 1, body)
            if frame == 1 {
                let gold = Color(red: 1, green: 0.86, blue: 0.35)
                fill(hand + 2 * out, 0, gold); fill(hand + 3 * out, 1, gold); fill(hand + 2 * out, 3, gold)
            }
            return
        }

        guard case .wave(let frame, let compact, _, let color, let pennant) = pose else { return }
        // Pole in the raised hand, flag rippling at the top, out to that side.
        let top = compact ? -3 : -8
        let flagHeight = compact ? 2 : 4
        let poleX = flagLeft ? 0 : 11
        for y in top...3 { fill(poleX, y, pole) }
        let length = compact ? 5 : 6
        for step in 1...length {
            let x = flagLeft ? poleX - step : poleX + step
            let dip = ((step + frame) / 2) % 2
            let rows = pennant ? max(1, flagHeight - (step - 1) * flagHeight / length) : flagHeight
            for y in top..<(top + rows) { fill(x, y + dip, color) }
        }
    }

    /// A puff of smoke where a character was, `progress` running 0 to 1. The body fades in the first quarter.
    static func drawPoof(progress: Double, in context: GraphicsContext, foot: CGPoint, pixel: CGFloat) {
        let p = min(max(progress, 0), 1)
        if p < 0.25 {
            var faded = context
            faded.opacity = 1 - p * 4
            draw(.stand(.front), in: faded, foot: foot, pixel: pixel)
        }
        let center = CGPoint(x: foot.x, y: foot.y - bodyRows * pixel / 2)
        let radius = (2 + 5 * p) * pixel
        let size = (p < 0.5 ? 2 : 1) * pixel
        for index in 0..<8 {
            let angle = Double(index) / 8 * 2 * .pi + 0.4
            // Snapped to the pixel grid so the smoke stays as crisp as the character.
            let x = ((center.x + cos(angle) * radius) / pixel).rounded() * pixel
            let y = ((center.y + sin(angle) * radius * 0.6) / pixel).rounded() * pixel
            context.fill(Path(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)),
                         with: .color(.white.opacity(0.85 * (1 - p))))
        }
        // A brighter core for the first instant.
        if p < 0.3 {
            context.fill(Path(CGRect(x: center.x - 2 * pixel, y: center.y - pixel, width: 4 * pixel, height: 2 * pixel)),
                         with: .color(.white.opacity(0.9 * (1 - p / 0.3))))
        }
    }

    /// A backpack stuffed with context, on its back (the side it walks away from).
    private static func drawPack(_ pack: Load, facing: Facing, fill: (Int, Int, Color) -> Void) {
        let canvas = Color(red: 0.42, green: 0.55, blue: 0.36), strap = Color(red: 0.3, green: 0.4, blue: 0.26)
        // Written for a pack on the left; mirrored when it faces left.
        let mirror = facing == .left
        func put(_ x: Int, _ y: Int, _ color: Color) { fill(mirror ? 11 - x : x, y, color) }
        let big = pack == .full
        let columns = big ? -3...(-1) : -2...(-1)
        let rows = big ? 0...5 : 1...4
        for x in columns { for y in rows { put(x, y, canvas) } }
        put(-1, rows.lowerBound + 1, strap)
        if big { put(-2, -1, canvas); put(-3, rows.upperBound, strap) }
    }

    /// Props sit beside the body on the side it faces (right when facing front), within rows -3...6
    /// so they fit in the menu bar strip.
    private static func drawProp(_ prop: Prop, facing: Facing, fill: (Int, Int, Color) -> Void) {
        let mirror = facing == .left
        // Written for the right-hand side; mirrored across the body for the left.
        func put(_ x: Int, _ y: Int, _ color: Color) { fill(mirror ? 11 - x : x, y, color) }
        let paper = Color(white: 0.95), steel = Color(white: 0.7), wood = Color(red: 0.55, green: 0.36, blue: 0.2)
        switch prop {
        case .book:
            let cover = Color(red: 0.35, green: 0.55, blue: 0.95)
            for y in 2...4 { put(12, y, paper); put(13, y, cover) }
        case .pencil:
            put(12, 4, Color(white: 0.25))
            put(13, 3, Color(red: 0.98, green: 0.8, blue: 0.25))
            put(14, 2, Color(red: 0.98, green: 0.8, blue: 0.25))
            put(15, 1, Color(red: 0.95, green: 0.55, blue: 0.6))
        case .magnifier:
            for (x, y) in [(13, 0), (14, 0), (12, 1), (15, 1), (12, 2), (15, 2), (13, 3), (14, 3)] { put(x, y, steel) }
            put(12, 4, wood)
        case .hammer(let frame):
            if frame == 0 {
                for y in 1...3 { put(12, y, wood) }
                for x in 11...13 { put(x, 0, steel) }
            } else {
                put(12, 3, wood); put(13, 3, wood)
                for y in 2...4 { put(14, y, steel) }
            }
        case .snooze(let frame):
            // Little breaths drifting up from the head.
            let faint = Color.white.opacity(0.7)
            if frame % 2 == 0 { put(10, -1, faint); put(12, -3, faint.opacity(0.6)) } else { put(11, -2, faint) }
        case .sparkle(let frame):
            let gold = Color(red: 1, green: 0.86, blue: 0.35)
            let points = frame % 2 == 0 ? [(-2, 0), (13, -1), (5, -3), (14, 3)] : [(-1, -2), (12, 1), (8, -3), (-2, 3)]
            for (x, y) in points { fill(x, y, gold) }
        }
    }
}
