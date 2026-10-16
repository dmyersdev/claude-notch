import CoreGraphics
import Foundation

/// What the open panel shows, and how much room it needs: sessions waiting on you get a full-width row
/// each (taller when there's a prompt or a question to answer), everyone else a tile in a grid below.
struct PanelLayout: Equatable {
    static let maxWaiting = 3
    static let tileColumns = 3
    static let maxTileRows = 2
    /// More questions than this and the row just offers to answer in Claude's own window.
    static let maxInlineQuestions = 2

    /// The height of each waiting row shown, in order.
    var rows: [CGFloat] = []
    /// Tiles shown.
    var tiles = 0
    /// Sessions that didn't fit, shown as "+N more".
    var hidden = 0
    /// Sessions tucked away, listed as a row of names at the bottom.
    var away = 0

    var waiting: Int { rows.count }
    var tileRows: Int { (tiles + Self.tileColumns - 1) / Self.tileColumns }
    var isEmpty: Bool { waiting == 0 && tiles == 0 }

    static let largest = PanelLayout(rows: Array(repeating: questionRowHeight(questions: maxInlineQuestions, send: true),
                                                 count: maxWaiting),
                                     tiles: tileColumns * maxTileRows, away: 1)

    init(rows: [CGFloat] = [], tiles: Int = 0, hidden: Int = 0, away: Int = 0) {
        self.rows = rows
        self.tiles = tiles
        self.hidden = hidden
        self.away = away
    }

    /// `asks` of the `waiting` rows hold a permission prompt; the rest are plain.
    init(waiting: Int, asks: Int = 0, tiles: Int = 0, hidden: Int = 0, away: Int = 0) {
        self.init(rows: Array(repeating: NotchMetrics.askRowHeight, count: asks)
                    + Array(repeating: NotchMetrics.waitingRowHeight, count: waiting - asks),
                  tiles: tiles, hidden: hidden, away: away)
    }

    /// `agents` are the sessions on show; `away` counts the ones tucked away.
    init(agents: [Agent], away: Int = 0) {
        let sections = Self.sections(agents)
        self.init(rows: sections.waiting.map(Self.rowHeight), tiles: sections.others.count,
                  hidden: agents.count - sections.waiting.count - sections.others.count, away: away)
    }

    static func rowHeight(for agent: Agent) -> CGFloat {
        if agent.need == .yourTurn, agent.hasReview { return NotchMetrics.reviewRowHeight }
        guard let request = agent.ask?.request else { return NotchMetrics.waitingRowHeight }
        guard request.isQuestion else { return NotchMetrics.askRowHeight }
        return request.questions.count > maxInlineQuestions
            ? NotchMetrics.waitingRowHeight
            : questionRowHeight(questions: request.questions.count, send: needsSend(request.questions))
    }

    /// One plain question answers on a tap; anything more needs a Send button.
    static func needsSend(_ questions: [Question]) -> Bool { questions.count > 1 || questions.contains(where: \.multiSelect) }

    /// Room for the summary line plus, per question, its text and a row of options.
    static func questionRowHeight(questions: Int, send: Bool) -> CGFloat {
        NotchMetrics.waitingRowHeight + CGFloat(questions) * 46 + (send ? 34 : 0)
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
