import Foundation
import Testing
@testable import ClaudeNotch

struct UsageTests {
    func line(id: String, model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0, read: Int = 0,
              write5m: Int = 0, write1h: Int = 0, sidechain: Bool = false) -> String {
        let usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read,
            "cache_creation_input_tokens": write5m + write1h,
            "cache_creation": ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h],
        ]
        let entry: [String: Any] = ["type": "assistant", "isSidechain": sidechain,
                                    "message": ["id": id, "model": model, "usage": usage]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    func read(_ lines: [String]) -> SessionUsage {
        var usage = SessionUsage(), seen = Set<String>()
        UsageReader.apply(Data((lines.joined(separator: "\n") + "\n").utf8), to: &usage, seen: &seen)
        return usage
    }

    @Test func countsEachResponseOnce() {
        let one = line(id: "m1", input: 1_000_000)
        // Opus 5.5 input is $4 per million; the duplicate line (another content block) adds nothing.
        #expect(read([one, one]).costUSD == 4)
    }

    @Test func pricesEveryKindOfToken() {
        let usage = read([line(id: "m1", output: 1_000_000, read: 1_000_000, write5m: 1_000_000, write1h: 1_000_000)])
        // 20 output + 0.20 read + 5 (1.25x) + 8 (2x)
        #expect(abs(usage.costUSD - 33.2) < 0.0001)
    }

    @Test func contextIsTheLatestMainThreadResponse() {
        let usage = read([
            line(id: "m1", input: 10, read: 100_000, write5m: 5_000, write1h: 0),
            line(id: "m2", input: 2, output: 500, read: 300_000),
            line(id: "s1", input: 900_000, sidechain: true),
        ])
        #expect(usage.contextTokens == 300_502)
        #expect(abs(usage.contextFraction - 0.300502) < 0.000001)
    }

    @Test func startTimeComesFromTheFirstLine() {
        let first = #"{"type":"queue-operation","timestamp":"2026-10-15T22:20:23.222Z"}"#
        let usage = read([first, line(id: "m1", input: 1)])
        #expect(usage.startedAt == UsageReader.timestamp("2026-10-15T22:20:23.222Z"))
        #expect(usage.startedAt != nil)
    }

    @Test func modelsMapToTheirWindows() {
        #expect(Pricing.for("claude-opus-5-5").contextWindow == 1_000_000)
        #expect(Pricing.for("claude-haiku-4-5-20251001").contextWindow == 200_000)
        #expect(Pricing.for("claude-sonnet-4-5[1m]").contextWindow == 1_000_000)
        #expect(Pricing.for("claude-opus-4-1").input == 15)
        #expect(Pricing.for("claude-opus-5").input == 5)
        #expect(Pricing.for(nil) == Pricing.fallback)
    }

    @Test func loadThresholds() {
        #expect(Load(fraction: 0.39) == .light)
        #expect(Load(fraction: 0.41) == .heavy)
        #expect(Load(fraction: 0.71) == .full)
    }

    @Test func readsOnlyWhatWasAppended() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data((line(id: "m1", input: 1_000_000) + "\n").utf8).write(to: url)
        let reader = UsageReader()
        #expect(await reader.usage(transcript: url.path)?.costUSD == 4)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // A complete line and a half-written one.
        try handle.write(contentsOf: Data((line(id: "m2", input: 1_000_000) + "\n{\"type\":\"assis").utf8))
        try handle.close()
        #expect(await reader.usage(transcript: url.path)?.costUSD == 8)
        #expect(await reader.usage(transcript: url.path)?.costUSD == 8)
    }
}
