import Foundation
import Network
import os

let hookLog = Logger(subsystem: "com.dmyersdev.claudenotch", category: "hooks")

/// A tiny HTTP endpoint on 127.0.0.1 that Claude Code hooks post their event JSON to.
/// `/event` is answered with 204 straight away so a hook never waits on the app. `/permission` is held
/// open for a while (`holdSeconds(for:)`) so the user can answer from the notch; the reply body is the hook's output.
final class HookServer: Sendable {
    static let port: UInt16 = 47474
    /// Long enough to glance up and click; questions get longer, since they take reading.
    static let holdSeconds: Double = 20
    static let questionHoldSeconds: Double = 60
    static func holdSeconds(for request: PermissionRequest) -> Double {
        request.isQuestion ? questionHoldSeconds : holdSeconds
    }
    private static let maxRequest = 8 << 20

    typealias Reply = @Sendable (PermissionDecision?) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "claude-notch.hooks")
    private let onEvent: @Sendable (HookEvent) -> Void
    /// Hands over a permission request plus how to answer it; returns a token for `onExpire`.
    private let onPermission: @Sendable (HookEvent, @escaping Reply) async -> UUID?
    private let onExpire: @Sendable (UUID) -> Void

    init(onEvent: @escaping @Sendable (HookEvent) -> Void,
         onPermission: @escaping @Sendable (HookEvent, @escaping Reply) async -> UUID?,
         onExpire: @escaping @Sendable (UUID) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.onEvent = onEvent
        self.onPermission = onPermission
        self.onExpire = onExpire
    }

    /// `onFailure` runs if the port can't be bound (another copy of the app, say).
    func start(onFailure: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed = state { onFailure() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.route(request, on: connection)
            } else if isComplete || error != nil || buffer.count > Self.maxRequest {
                hookLog.error("dropped connection: \(buffer.count) bytes, error \(String(describing: error), privacy: .public)")
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
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
