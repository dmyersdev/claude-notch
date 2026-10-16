import Foundation

/// What the open panel shows, and how much room it needs: sessions waiting on you get a full-width row
/// each (taller when there's a prompt to answer), everyone else a tile in a grid below.
struct PanelLayout: Equatable {
    static let maxWaiting = 3
    static let tileColumns = 3
    static let maxTileRows = 2

    /// Waiting rows shown, and how many of those hold a prompt.
    var waiting = 0
    var asks = 0
    /// Tiles shown.
    var tiles = 0
    /// Sessions that didn't fit, shown as "+N more".
    var hidden = 0
    /// Sessions tucked away, listed as a row of names at the bottom.
    var away = 0

    var tileRows: Int { (tiles + Self.tileColumns - 1) / Self.tileColumns }
    var isEmpty: Bool { waiting == 0 && tiles == 0 }

    static let largest = PanelLayout(waiting: maxWaiting, asks: maxWaiting, tiles: tileColumns * maxTileRows, away: 1)

    init(waiting: Int = 0, asks: Int = 0, tiles: Int = 0, hidden: Int = 0, away: Int = 0) {
        self.waiting = waiting
        self.asks = asks
        self.tiles = tiles
        self.hidden = hidden
        self.away = away
    }

    /// `agents` are the sessions on show; `away` counts the ones tucked away.
    init(agents: [Agent], away: Int = 0) {
        self.away = away
        let sections = Self.sections(agents)
        waiting = sections.waiting.count
        asks = sections.waiting.filter { $0.ask != nil }.count
        tiles = sections.others.count
        hidden = agents.count - waiting - tiles
    }

    /// Permission prompts first, then longest waiting; the rest by whoever started first.
    static func sections(_ agents: [Agent]) -> (waiting: [Agent], others: [Agent]) {
        let waiting = agents.filter(\.needsAttention).sorted {
            ($0.need == .permission ? 0 : 1, $0.waitingSince ?? .distantFuture)
                < ($1.need == .permission ? 0 : 1, $1.waitingSince ?? .distantFuture)
        }
        let others = agents.filter { !$0.needsAttention }
        return (Array(waiting.prefix(maxWaiting)), Array(others.prefix(tileColumns * maxTileRows)))
    }
}
