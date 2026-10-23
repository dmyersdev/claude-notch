import SwiftUI
import Testing
@testable import ClaudeNotch

/// Renders the notch to /tmp/nc for eyeballing. Not an assertion test.
@MainActor struct SnapshotRender {
    let metrics = NotchMetrics.make(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    safeAreaTop: 0, leftArea: nil, rightArea: nil, visibleMaxY: 1056)

    func write(_ view: some View, _ name: String) throws {
        try FileManager.default.createDirectory(atPath: "/tmp/nc", withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view.padding(10).background(Color(red: 0.45, green: 0.78, blue: 0.75)))
        renderer.scale = 3
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/nc/\(name).png"))
    }

    @Test func renderPoses() throws {
        for attention in [false, true] {
            let size = metrics.shapeSize(expanded: true)
            let view = ZStack(alignment: .top) {
                NotchShape(topRadius: metrics.topRadius, bottomRadius: 10).fill(.black)
                Canvas { context, size in
                    let floor = size.height - metrics.floorInset
                    let left: Sprite.Pose = attention ? .wave(frame: 0, compact: true, flagLeft: true) : .walk(.right, step: 0)
                    Sprite.draw(left, in: context, foot: CGPoint(x: 40, y: floor), pixel: metrics.pixel)
                    Sprite.draw(.walk(.left, step: 1), in: context, foot: CGPoint(x: 80, y: floor), pixel: metrics.pixel)
                    Sprite.draw(attention ? Sprite.wave(for: .yourTurn, frame: 0, compact: true, flagLeft: false) : .stand(.front),
                                in: context, foot: CGPoint(x: size.width - 90, y: floor), pixel: metrics.pixel)
                }
                if attention {
                    WaitingBadge(count: 2, blocked: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, metrics.topRadius + 8)
                }
            }
            .frame(width: size.width, height: size.height)
            try write(view, "notch-\(attention ? "attention" : "walking")")
        }
    }

    @Test func renderLineup() throws {
        let poses: [(Sprite.Pose, Sprite.Prop?, Int)] = [
            (.walk(.right, step: 0), .pencil, 0), (.walk(.left, step: 1), .book, 0), (.stand(.right), .hammer(frame: 0), 0),
            (.stand(.right), .hammer(frame: 1), 0), (.walk(.right, step: 0), .magnifier, 0), (.stand(.front), .snooze(frame: 0), 0),
            (.stand(.front), .sparkle(frame: 0), 2), (.wave(frame: 0, compact: true), nil, 0),
            (Sprite.wave(for: .yourTurn, frame: 1, compact: true, flagLeft: true), nil, 0),
            (.greet(.right, frame: 0), nil, 0), (.greet(.left, frame: 1), nil, 0),
            (.stand(.front), .bubble(frame: 0), 0), (.stand(.front), .parcel(passed: true), 0),
            (.stand(.front), .parcel(passed: false), 0),
            (Sprite.wave(for: .permission, frame: 0, compact: true, flagLeft: false, waited: 300), nil, 0),
            (Sprite.wave(for: .yourTurn, frame: 0, compact: true, flagLeft: false, waited: 900), nil, 0),
        ]
        let packs: [Load] = [.heavy, .full, .heavy, .full]
        let poofs = [0.1, 0.35, 0.7]
        let size = CGSize(width: CGFloat(poses.count + 3) * 50 + 20, height: metrics.notchHeight)
        let view = Canvas { context, size in
            let floor = size.height - metrics.floorInset
            for (index, (pose, prop, lift)) in poses.enumerated() {
                Sprite.draw(pose, in: context, foot: CGPoint(x: 30 + CGFloat(index) * 50, y: floor),
                            pixel: metrics.pixel, prop: prop, lift: lift, pack: index < packs.count ? packs[index] : .light,
                            stickers: index == poses.count - 1 ? ["Bash", "Edit", "Read"].map(Sprite.stickerColor) : [])
            }
            for (index, progress) in poofs.enumerated() {
                Sprite.drawPoof(progress: progress, in: context,
                                foot: CGPoint(x: 30 + CGFloat(poses.count + index) * 50, y: floor), pixel: metrics.pixel)
            }
            // Two sub-agents trailing the first one.
            for index in 0..<2 {
                Sprite.draw(.walk(.right, step: index), in: context, foot: CGPoint(x: 8 - CGFloat(index) * 14, y: floor), pixel: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.black)
        try write(view, "lineup")
    }

    @Test func renderWelcome() throws {
        try write(WelcomeView(hooks: HookStatus()) {}.background(Color(nsColor: .windowBackgroundColor)), "welcome")
    }

    @Test func renderMenuBarIcon() throws {
        let view = HStack(spacing: 16) {
            ForEach([false, true], id: \.self) { flag in
                Image(nsImage: MenuBarIcon.image(flag: flag)).renderingMode(.template)
                    .interpolation(.none).resizable().frame(width: 18 * 4, height: 16 * 4)
            }
        }
        .foregroundStyle(.black)
        .padding(8)
        .background(.white)
        try write(view, "menubar-icon")
    }

    @Test func renderOpenPanel() throws {
        let store = AgentStore()
        store.spawn(); store.spawn(); store.spawn(); store.spawn()
        store.hold(HookEvent(sessionID: "ask", kind: .permissionRequest(PermissionRequest(
            summary: "Run npm run build", tool: "Bash", suggestions: Data("[]".utf8))), cwd: "/x/freeCodeCamp")) { _ in }
        store.hold(HookEvent(sessionID: "q", kind: .permissionRequest(PermissionRequest(
            summary: "Which database?", tool: "AskUserQuestion",
            questions: [Question(text: "Which database should the cache use?", header: "Cache",
                                 options: [.init(label: "Redis"), .init(label: "SQLite"), .init(label: "In memory")],
                                 multiSelect: false)])), cwd: "/x/react")) { _ in }
        var edit = HookEvent(sessionID: "done", kind: .toolEnd, cwd: "/x/vscode")
        edit.step = Step(tool: "Edit", summary: "Editing NotchView.swift", at: Date(),
                         change: FileChange(path: "/x/NotchView.swift", added: 42, removed: 7))
        store.apply(edit)
        var test = HookEvent(sessionID: "done", kind: .toolEnd, cwd: "/x/vscode")
        test.step = Step(tool: "Bash", summary: "Running xcodebuild test", at: Date(), isTest: true)
        store.apply(test)
        var stop = HookEvent(sessionID: "done", kind: .stop, cwd: "/x/vscode")
        stop.lastMessage = "Reworked the panel: waiting sessions come first, prompts show the whole command, and the closed notch gets a badge."
        store.apply(stop)
        store.setUsage(SessionUsage(model: "claude-opus-5-5", contextTokens: 520_000, costUSD: 3.41,
                                    title: "Ship the notch panel"), for: "done")
        store.setUsage(SessionUsage(model: "claude-opus-5-5", contextTokens: 120_000, costUSD: 0.62), for: "ask")
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "old", cwd: "/x/awesome", name: "Draft the launch post",
                                              status: "idle", statusSince: Date(timeIntervalSinceNow: -3600))])
        store.apply(HookEvent(sessionID: "meh", kind: .stop, cwd: "/x/build-your-own-x"))
        store.tuckAway("meh")
        store.planUsage = PlanUsage(fiveHour: 42, weekly: 83, at: Date(timeIntervalSinceNow: -300))
        let state = NotchState()
        let size = metrics.openSize(state.layout(store))
        let view = ZStack(alignment: .top) {
            NotchShape(topRadius: metrics.topRadius, bottomRadius: 24).fill(.black)
            OpenNotchView(metrics: metrics, store: store, state: state)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(NotchShape(topRadius: metrics.topRadius, bottomRadius: 24))
        .environment(\.colorScheme, .dark)
        try write(view, "notch-open")
    }
}

/// The closed notch in each style: lopsided wings fitted to the menu bar, compact, and under the menu bar.
@MainActor struct ClosedStyleRender {
    func render(_ style: NotchStyle, left: CGFloat, right: CGFloat, name: String) throws {
        var metrics = NotchMetrics.make(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                        safeAreaTop: 0, leftArea: nil, rightArea: nil, visibleMaxY: 1056)
        metrics.style = style
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "a", kind: .prompt, cwd: "/x/react"))
        store.apply(HookEvent(sessionID: "b", kind: .needs(.permission), cwd: "/x/linux"))
        let state = NotchState()
        state.leftWing = left
        state.rightWing = right
        let view = NotchView(metrics: metrics, store: store, state: state)
            .frame(width: metrics.panelFrame.width, height: 90)
        try FileManager.default.createDirectory(atPath: "/tmp/nc", withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view.background(Color(red: 0.45, green: 0.78, blue: 0.75)))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/nc/closed-\(name).png"))
    }

    @Test func renderStyles() throws {
        try render(.wings, left: 70, right: 180, name: "lopsided")
        try render(.wings, left: 0, right: 220, name: "one-side")
        try render(.compact, left: 0, right: 50, name: "compact")
        try render(.below, left: 180, right: 180, name: "below")
    }
}

/// A first sketch of the proposed original character ("Hobkin"), for the naming decision. Not used by the app.
@MainActor struct HobkinSketch {
    static let body = Color(red: 0.56, green: 0.73, blue: 0.59)
    static let shade = Color(red: 0.31, green: 0.48, blue: 0.35)
    static let face = Color(red: 0.17, green: 0.18, blue: 0.21)
    static let eye = Color(red: 0.91, green: 1, blue: 0.96)

    /// 12 columns; (0,0) is the top left of the body. `accent` is the scarf, one colour per agent.
    static func draw(_ context: GraphicsContext, at foot: CGPoint, pixel: CGFloat, accent: Color,
                     tuftUp: Bool, flag: Color? = nil, step: Int = 0) {
        let origin = CGPoint(x: foot.x - 6 * pixel, y: foot.y - 9 * pixel)
        func fill(_ x: Int, _ y: Int, _ c: Color) {
            context.fill(Path(CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel,
                                     width: pixel, height: pixel)), with: .color(c))
        }
        // The ear tuft: straight up when it needs you, flopped over otherwise.
        if tuftUp { for y in -3...0 { fill(7, y, shade) } } else { fill(7, 0, shade); fill(8, -1, shade); fill(9, -1, shade) }
        // Teardrop body: narrow at the top, round at the bottom.
        let rows: [(Int, Int)] = [(4, 7), (3, 8), (2, 9), (2, 9), (2, 9), (2, 9), (3, 8)]
        for (y, span) in rows.enumerated() { for x in span.0...span.1 { fill(x, y + 1, body) } }
        for x in 3...8 { fill(x, 7, shade) }
        // Face window with two bright eyes.
        for y in 2...4 { for x in 3...8 { fill(x, y, face) } }
        fill(4, 3, eye); fill(7, 3, eye)
        // Scarf in the agent's colour.
        for x in 2...9 { fill(x, 5, accent) }
        fill(9, 6, accent)
        // Little feet.
        for x in (step == 0 ? [3, 4, 7, 8] : [3, 7]) { fill(x, 8, shade) }
        if let flag {
            for y in -4...4 { fill(11, y, Color(white: 0.85)) }
            for x in 12...15 { for y in -4...(-2) { fill(x, y, flag) } }
        }
    }

    @Test func renderSketch() throws {
        let teal = Color(red: 0.25, green: 0.72, blue: 0.69), plum = Color(red: 0.61, green: 0.42, blue: 0.8)
        let butter = Color(red: 0.95, green: 0.82, blue: 0.42)
        let view = Canvas { context, size in
            let floor = size.height - 8
            Self.draw(context, at: CGPoint(x: 40, y: floor), pixel: 4, accent: teal, tuftUp: false)
            Self.draw(context, at: CGPoint(x: 110, y: floor), pixel: 4, accent: plum, tuftUp: false, step: 1)
            Self.draw(context, at: CGPoint(x: 180, y: floor), pixel: 4, accent: butter, tuftUp: false)
            Self.draw(context, at: CGPoint(x: 260, y: floor), pixel: 4, accent: teal, tuftUp: true,
                 flag: Color(red: 1, green: 0.27, blue: 0.23))
        }
        .frame(width: 340, height: 80)
        .background(.black)
        let renderer = ImageRenderer(content: view.padding(10).background(Color(red: 0.45, green: 0.78, blue: 0.75)))
        renderer.scale = 3
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: "/tmp/nc", withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: "/tmp/nc/hobkin-sketch.png"))
    }
}
