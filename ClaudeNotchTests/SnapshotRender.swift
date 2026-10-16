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
        ]
        let packs: [Load] = [.heavy, .full, .heavy, .full]
        let poofs = [0.1, 0.35, 0.7]
        let size = CGSize(width: CGFloat(poses.count + 3) * 50 + 20, height: metrics.notchHeight)
        let view = Canvas { context, size in
            let floor = size.height - metrics.floorInset
            for (index, (pose, prop, lift)) in poses.enumerated() {
                Sprite.draw(pose, in: context, foot: CGPoint(x: 30 + CGFloat(index) * 50, y: floor),
                            pixel: metrics.pixel, prop: prop, lift: lift, pack: index < packs.count ? packs[index] : .light)
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
        store.hold(HookEvent(sessionID: "ask", kind: .permissionRequest(summary: "Run rm -rf build"), cwd: "/x/freeCodeCamp")) { _ in }
        store.apply(HookEvent(sessionID: "done", kind: .stop, cwd: "/x/vscode"))
        store.setUsage(SessionUsage(model: "claude-opus-5-5", contextTokens: 520_000, costUSD: 3.41,
                                    title: "Ship the notch panel"), for: "done")
        store.setUsage(SessionUsage(model: "claude-opus-5-5", contextTokens: 120_000, costUSD: 0.62), for: "ask")
        let size = metrics.openSize(PanelLayout(agents: store.agents))
        let view = ZStack(alignment: .top) {
            NotchShape(topRadius: metrics.topRadius, bottomRadius: 22).fill(.black)
            OpenNotchView(metrics: metrics, store: store)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(NotchShape(topRadius: metrics.topRadius, bottomRadius: 22))
        .environment(\.colorScheme, .dark)
        try write(view, "notch-open")
    }
}
