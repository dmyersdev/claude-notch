import Foundation

/// What a session has used so far, read from its Claude Code transcript.
struct SessionUsage: Equatable, Sendable {
    var model: String?
    /// Tokens in the context at the last main-thread response.
    var contextTokens = 0
    /// What the session would have cost at API list prices (subscriptions aren't billed per token).
    var costUSD = 0.0
    /// When the transcript began, which may be long before the notch first heard from the session.
    var startedAt: Date?
    /// The conversation's latest title, for sessions the registry doesn't name.
    var title: String?
    /// The window the agent itself reported (Codex does), instead of looking it up by model.
    var windowOverride: Int?
    /// Whether `costUSD` means anything: we only know Claude's prices.
    var priced = true

    var contextWindow: Int { windowOverride ?? Pricing.for(model).contextWindow }
    var contextFraction: Double { min(1, Double(contextTokens) / Double(contextWindow)) }
}

/// How full a session's context is, as its character shows it.
enum Load: Equatable, Sendable {
    case light
    /// Over 40%: carries a backpack.
    case heavy
    /// Over 70%: a big, bulging pack and a slower walk.
    case full

    init(fraction: Double) {
        self = fraction > 0.7 ? .full : fraction > 0.4 ? .heavy : .light
    }
}

/// List prices per million tokens and context window, by model family.
struct Pricing: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var contextWindow: Int

    /// Prompt cache writes cost 1.25x input for 5 minutes, 2x for an hour.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }

    private static let million = 1_000_000

    /// Checked in order, so more specific prefixes come first.
    static let table: [(prefix: String, pricing: Pricing)] = [
        ("claude-fable-5-1", Pricing(input: 10, output: 50, cacheRead: 0.25, contextWindow: million)),
        ("claude-mythos", Pricing(input: 10, output: 50, cacheRead: 0.25, contextWindow: million)),
        ("claude-fable", Pricing(input: 10, output: 50, cacheRead: 1, contextWindow: million)),
        ("claude-opus-5-5", Pricing(input: 4, output: 20, cacheRead: 0.2, contextWindow: million)),
        ("claude-opus-5", Pricing(input: 5, output: 25, cacheRead: 0.5, contextWindow: million)),
        ("claude-opus-4-8", Pricing(input: 5, output: 25, cacheRead: 0.5, contextWindow: million)),
        ("claude-opus-4-7", Pricing(input: 5, output: 25, cacheRead: 0.5, contextWindow: million)),
        ("claude-opus-4-6", Pricing(input: 5, output: 25, cacheRead: 0.5, contextWindow: million)),
        ("claude-opus-4-5", Pricing(input: 5, output: 25, cacheRead: 0.5, contextWindow: 200_000)),
        ("claude-opus-4", Pricing(input: 15, output: 75, cacheRead: 1.5, contextWindow: 200_000)),
        ("claude-sonnet-5", Pricing(input: 2, output: 10, cacheRead: 0.2, contextWindow: million)),
        ("claude-sonnet-4-6", Pricing(input: 3, output: 15, cacheRead: 0.3, contextWindow: million)),
        ("claude-sonnet-4", Pricing(input: 3, output: 15, cacheRead: 0.3, contextWindow: 200_000)),
        ("claude-haiku-5-5", Pricing(input: 0.1, output: 0.5, cacheRead: 0.01, contextWindow: million)),
        ("claude-haiku-4-5", Pricing(input: 1, output: 5, cacheRead: 0.1, contextWindow: 200_000)),
    ]
    /// Unknown models: priced like the current Opus, with the smaller window so the gauge errs on the full side.
    static let fallback = Pricing(input: 4, output: 20, cacheRead: 0.2, contextWindow: 200_000)

    static func `for`(_ model: String?) -> Pricing {
        guard let model else { return fallback }
        var pricing = table.first { model.hasPrefix($0.prefix) }?.pricing ?? fallback
        // "claude-sonnet-4-5[1m]" style IDs ask for the long context.
        if model.contains("[1m]") { pricing.contextWindow = million }
        return pricing
    }

    func cost(of usage: [String: Any]) -> Double {
        func tokens(_ key: String, in dict: [String: Any] = usage) -> Double { Double(dict[key] as? Int ?? 0) }
        let creation = usage["cache_creation"] as? [String: Any]
        let write1h = creation.map { tokens("ephemeral_1h_input_tokens", in: $0) } ?? 0
        let write5m = creation.map { tokens("ephemeral_5m_input_tokens", in: $0) }
            ?? tokens("cache_creation_input_tokens")
        let dollars = tokens("input_tokens") * input + tokens("output_tokens") * output
            + tokens("cache_read_input_tokens") * cacheRead + write5m * cacheWrite5m + write1h * cacheWrite1h
        return dollars / 1_000_000
    }
}

/// Reads transcripts incrementally: each call only parses lines appended since the last one.
actor UsageReader {
    private struct Progress {
        var offset: UInt64 = 0
        var seen: Set<String> = []
        var usage = SessionUsage()
    }
    private var files: [String: Progress] = [:]

    func usage(transcript path: String) -> SessionUsage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var progress = files[path] ?? Progress()
        let size = (try? handle.seekToEnd()) ?? 0
        if size < progress.offset { progress = Progress() } // rewritten from scratch
        guard size > progress.offset else { return progress.usage }
        try? handle.seek(toOffset: progress.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return progress.usage
        }
        // Only whole lines; a half-written last line waits for next time.
        let complete = data[data.startIndex...lastNewline]
        Self.apply(complete, to: &progress.usage, seen: &progress.seen)
        progress.offset += UInt64(complete.count)
        files[path] = progress
        return progress.usage
    }

    func forget(_ path: String) { files[path] = nil }

    static func timestamp(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    static func apply(_ data: Data, to usage: inout SessionUsage, seen: inout Set<String>) {
        for line in data.split(separator: UInt8(ascii: "\n")) where line.count > 2 {
            if usage.startedAt == nil, let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let stamp = entry["timestamp"] as? String {
                usage.startedAt = timestamp(stamp)
            }
            if line.range(of: Data("\"custom-title\"".utf8)) != nil,
               let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               entry["type"] as? String == "custom-title", let title = entry["customTitle"] as? String, !title.isEmpty {
                usage.title = title
                continue
            }
            // Codex: `token_count` events carry the latest request's tokens and the model's window.
            if line.range(of: Data("\"token_count\"".utf8)) != nil,
               let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let payload = entry["payload"] as? [String: Any], payload["type"] as? String == "token_count" {
                let info = payload["info"] as? [String: Any]
                if let last = info?["last_token_usage"] as? [String: Any], let total = last["total_tokens"] as? Int {
                    usage.contextTokens = total
                }
                if let window = info?["model_context_window"] as? Int, window > 0 { usage.windowOverride = window }
                usage.priced = false
                continue
            }
            // Cheap filter before parsing: only assistant responses carry usage.
            guard line.range(of: Data("\"usage\"".utf8)) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let tokens = message["usage"] as? [String: Any]
            else { continue }
            let model = message["model"] as? String
            if model == "<synthetic>" { continue }
            // Each content block gets its own line with the same message ID and usage; count it once.
            if let id = message["id"] as? String {
                guard seen.insert(id).inserted else { continue }
            }
            usage.costUSD += Pricing.for(model).cost(of: tokens)
            // Sub-agents run in their own context; only the main thread fills this one.
            guard entry["isSidechain"] as? Bool != true else { continue }
            usage.model = model ?? usage.model
            usage.contextTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .reduce(0) { $0 + (tokens[$1] as? Int ?? 0) }
        }
    }
}
