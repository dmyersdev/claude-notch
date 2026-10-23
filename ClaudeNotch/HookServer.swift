import Foundation
import Network
import os

let hookLog = Logger(subsystem: "com.dmyersdev.claudenotch", category: "hooks")

/// A tiny HTTP endpoint on 127.0.0.1 that Claude Code hooks post their event JSON to.
/// `/event` is answered with 204 straight away so a hook never waits on the app. `/permission` is held
/// open for a while (`holdSeconds(for:)`) so the user can answer from the notch; the reply body is the hook's output.
///
/// It listens on the first free port from 47474 and writes that port to `~/.claude/claude-notch-port`, which the
/// hook commands read. If the listener fails (the network stack resets after sleep, say) it starts over.
final class HookServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 47474
    static let ports: ClosedRange<UInt16> = 47474...47483
    /// Where the hooks find the port. Written each time the server comes up.
    static var portFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/claude-notch-port")
    }
    /// Long enough to glance up and click; questions get longer, since they take reading.
    static let holdSeconds: Double = 20
    static let questionHoldSeconds: Double = 60
    static func holdSeconds(for request: PermissionRequest) -> Double {
        request.isQuestion ? questionHoldSeconds : holdSeconds
    }
    private static let maxRequest = 8 << 20
    /// A connection that hasn't sent a whole request by now is dropped.
    static let requestTimeout: Double = 10

    typealias Reply = @Sendable (PermissionDecision?) -> Void

    enum State: Equatable, Sendable {
        case starting
        case listening(port: UInt16)
        /// Every port was busy, or the listener keeps failing; it tries again on its own.
        case failed(String)
    }

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "claude-notch.hooks")
    private var listener: NWListener?
    private var retries = 0
    private var retryWork: DispatchWorkItem?

    private let onEvent: @Sendable (HookEvent) -> Void
    /// Hands over a permission request plus how to answer it; returns a token for `onExpire`.
    private let onPermission: @Sendable (HookEvent, @escaping Reply) async -> UUID?
    private let onExpire: @Sendable (UUID) -> Void
    private let onState: @Sendable (State) -> Void

    init(onEvent: @escaping @Sendable (HookEvent) -> Void,
         onPermission: @escaping @Sendable (HookEvent, @escaping Reply) async -> UUID?,
         onExpire: @escaping @Sendable (UUID) -> Void,
         onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.onEvent = onEvent
        self.onPermission = onPermission
        self.onExpire = onExpire
        self.onState = onState
    }

    func start() { queue.async { self.bind(Self.ports.lowerBound) } }

    /// Drops the listener and binds again from the first port: after waking from sleep, or when asked.
    func restart() {
        queue.async {
            self.retryWork?.cancel()
            self.listener?.cancel()
            self.listener = nil
            self.retries = 0
            self.bind(Self.ports.lowerBound)
        }
    }

    /// The next port to try after `port`, or nil when the range is used up.
    static func next(after port: UInt16) -> UInt16? { port < ports.upperBound ? port + 1 : nil }

    /// Seconds to wait before the `retries`th attempt to start over: 1, 2, 4… up to a minute.
    static func backoff(_ retries: Int) -> Double { min(60, pow(2, Double(min(retries, 6)))) }

    private func bind(_ port: UInt16) {
        onState(.starting)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return tryNext(after: port) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready:
                self.retries = 0
                Self.writePortFile(port)
                hookLog.info("listening on \(port)")
                self.onState(.listening(port: port))
            case .failed(let error):
                listener.cancel()
                self.listener = nil
                hookLog.error("listener on \(port) failed: \(String(describing: error), privacy: .public)")
                if case .posix(.EADDRINUSE) = error { self.tryNext(after: port) } else { self.retryLater() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
    }

    private func tryNext(after port: UInt16) {
        if let next = Self.next(after: port) { return bind(next) }
        onState(.failed("Ports \(Self.ports.lowerBound)–\(Self.ports.upperBound) are all busy"))
        retryLater()
    }

    private func retryLater() {
        let delay = Self.backoff(retries)
        retries += 1
        let work = DispatchWorkItem { [weak self] in self?.bind(Self.ports.lowerBound) }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Puts the port file back if something else changed or removed it.
    func ensurePortFile() {
        queue.async {
            guard let port = self.listener?.port?.rawValue, self.listener?.state == .ready else { return }
            let written = (try? String(contentsOf: Self.portFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if written != String(port) { Self.writePortFile(port) }
        }
    }

    private static func writePortFile(_ port: UInt16) {
        let url = portFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(port)\n".utf8).write(to: url, options: .atomic)
    }

    /// Per connection, so a slow or silent client can be dropped.
    private final class Pending: @unchecked Sendable { var routed = false }

    private func handle(_ connection: NWConnection) {
        let pending = Pending()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            if !pending.routed { connection.cancel() }
        }
        receive(on: connection, buffer: Data(), pending: pending)
    }

    private func receive(on connection: NWConnection, buffer: Data, pending: Pending) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                pending.routed = true
                self.route(request, on: connection)
            } else if isComplete || error != nil || buffer.count > Self.maxRequest {
                hookLog.error("dropped connection: \(buffer.count) bytes, error \(String(describing: error), privacy: .public)")
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer, pending: pending)
            }
        }
    }

    private func route(_ request: Request, on connection: NWConnection) {
        guard let event = HookEvent(json: request.body, pid: request.pid, agent: request.agent) else {
            hookLog.error("unreadable hook post, \(request.body.count) bytes")
            return send(nil, on: connection)
        }
        hookLog.info("\(request.path, privacy: .public) \(event.agent.rawValue, privacy: .public) \(String(describing: event.kind), privacy: .public) session \(event.sessionID, privacy: .public) pid \(event.pid ?? -1)")
        guard request.path == "/permission" else {
            onEvent(event)
            return send(nil, on: connection)
        }
        // Whichever comes first wins: the user's answer, the session moving on, or the timeout.
        let once = Once()
        guard case .permissionRequest(let request) = event.kind else { return send(nil, on: connection) }
        let reply: Reply = { [weak self] decision in
            guard once.claim() else { return }
            self?.send(decision.map { Self.hookOutput($0, for: request) }, on: connection)
        }
        let onPermission = onPermission, onExpire = onExpire, queue = queue
        let hold = Self.holdSeconds(for: request)
        Task {
            guard let token = await onPermission(event, reply) else { return }
            queue.asyncAfter(deadline: .now() + hold) {
                if !once.isClaimed { onExpire(token) }
            }
        }
    }

    private func send(_ body: Data?, on connection: NWConnection) {
        let head = body.map { "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \($0.count)\r\n" }
            ?? "HTTP/1.1 204 No Content\r\n"
        let response = Data((head + "Connection: close\r\n\r\n").utf8) + (body ?? Data())
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// What the PermissionRequest hook prints for each answer.
    static func hookOutput(_ decision: PermissionDecision, for request: PermissionRequest) -> Data {
        var verdict: [String: Any] = ["behavior": "allow"]
        switch decision {
        case .allow: break
        case .deny: verdict = ["behavior": "deny", "message": "Denied from the notch."]
        case .denyBecause(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            verdict = ["behavior": "deny", "message": trimmed.isEmpty ? "Denied from the notch." : "Denied: \(trimmed)"]
        case .always:
            if let data = request.suggestions, let rules = try? JSONSerialization.jsonObject(with: data) {
                verdict["updatedPermissions"] = rules
            }
        case .answer(let answers):
            // The tool reads `answers` from its input: a label per question, or a list for multi-select.
            var input = (try? JSONSerialization.jsonObject(with: request.input) as? [String: Any]) ?? [:]
            var filled: [String: Any] = [:]
            for question in request.questions {
                guard let picked = answers[question.text], !picked.isEmpty else { continue }
                filled[question.text] = question.multiSelect ? picked : picked[0]
            }
            input["answers"] = filled
            verdict["updatedInput"] = input
        }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": verdict]]
        return (try? JSONSerialization.data(withJSONObject: output, options: .sortedKeys)) ?? Data()
    }

    struct Request: Equatable {
        var path: String
        var body: Data
        var pid: Int32?
        var agent: AgentKind = .claude
    }

    /// A complete request's path, body and `X-Claude-PID` header, or nil while more bytes are due.
    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = header.split(separator: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var length = 0
        var pid: Int32?
        var agent = AgentKind.claude
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "content-length": length = Int(value) ?? 0
            case "x-claude-pid": pid = Int32(value)
            case "x-agent": agent = AgentKind(rawValue: value.lowercased()) ?? .claude
            default: break
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(path: path, body: Data(body.prefix(length)), pid: pid, agent: agent)
    }
}

/// Lets exactly one of several racing callers through.
private final class Once: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isClaimed: Bool { lock.withLock { $0 } }
    func claim() -> Bool {
        lock.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
