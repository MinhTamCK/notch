import AppKit
import FlyingFox
import Foundation
import NotchCore

/// The in-app server: hooks (local and remote) POST here; the UI updates directly.
/// Same HTTP API as the optional headless Node server, minus the WebSocket.
final class EmbeddedServer {
    private let model: AppModel
    private let machineToken: String   // report events / open + poll permissions
    private let operatorToken: String  // list sessions / decide (this Mac only)
    private let port: UInt16
    private let server: HTTPServer
    private var runTask: Task<Void, Never>?

    init(model: AppModel, machineToken: String, operatorToken: String, port: UInt16) {
        self.model = model
        self.machineToken = machineToken
        self.operatorToken = operatorToken
        self.port = port
        self.server = HTTPServer(port: port)
    }

    func start() async throws {
        await addRoutes()
        runTask = Task { try? await server.run() }
        for _ in 0..<20 {
            if await AppModel.isHealthy("http://127.0.0.1:\(port)") { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
        runTask?.cancel()
        throw NSError(domain: "notch", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not bind :\(port)"])
    }

    // MARK: Helpers

    /// Only loopback and the Tailscale private network may talk to the server —
    /// LAN and internet sources are rejected before auth is even considered.
    /// The policy itself lives in NotchCore.SourceFilter (unit-tested).
    static func allowedSource(_ request: HTTPRequest) -> Bool {
        switch request.remoteAddress {
        case .ip4(let ip, port: _): return SourceFilter.isAllowed(ip: ip)
        case .ip6(let ip, port: _): return SourceFilter.isAllowed(ip: ip)
        case .unix: return true
        case nil: return false
        }
    }

    private static let maxBodyBytes = 256 * 1024

    private func withinSizeLimit(_ request: HTTPRequest) -> Bool {
        guard let len = request.headers[HTTPHeader("Content-Length")].flatMap({ Int($0) }) else {
            // No Content-Length on a body-bearing method is suspicious — reject.
            return request.method == .GET
        }
        return len <= Self.maxBodyBytes
    }

    private func auth(_ request: HTTPRequest, requiresOperator: Bool) -> Bool {
        Self.allowedSource(request)
            && withinSizeLimit(request)
            && RoleAuth.allows(
                bearer: request.headers[HTTPHeader("Authorization")],
                requiresOperator: requiresOperator,
                machineToken: machineToken,
                operatorToken: operatorToken
            )
    }

    /// Machine role: report events, open + poll permissions. Operator implies it.
    private func machineOK(_ request: HTTPRequest) -> Bool { auth(request, requiresOperator: false) }

    /// Operator role: list sessions and decide — never granted to a reporting machine.
    private func operatorOK(_ request: HTTPRequest) -> Bool { auth(request, requiresOperator: true) }

    private func json(_ object: Any, status: HTTPStatusCode = .ok) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(statusCode: status, headers: [HTTPHeader("Content-Type"): "application/json"], body: data)
    }

    private func encoded<T: Encodable>(_ value: T) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(statusCode: .ok, headers: [HTTPHeader("Content-Type"): "application/json"], body: data)
    }

    private var unauthorized: HTTPResponse { json(["error": "unauthorized"], status: .unauthorized) }

    // MARK: Routes

    private func addRoutes() async {
        let model = model

        await server.appendRoute("GET /health") { request in
            guard Self.allowedSource(request) else { return HTTPResponse(statusCode: .forbidden) }
            return HTTPResponse(statusCode: .ok, headers: [HTTPHeader("Content-Type"): "application/json"],
                                body: Data(#"{"ok":true}"#.utf8))
        }

        await server.appendRoute("POST /api/events") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.machineOK(request) else { return self.unauthorized }
            guard let body = try? await request.bodyData,
                  let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: body)
            else { return self.json(["error": "bad envelope"], status: .badRequest) }
            let ok = await MainActor.run { model.applyEnvelope(envelope) }
            return ok ? self.json(["ok": true]) : self.json(["error": "missing machine or session_id"], status: .badRequest)
        }

        await server.appendRoute("GET /api/sessions") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.operatorOK(request) else { return self.unauthorized }
            struct Payload: Encodable { let sessions: [Session] }
            let sessions = await MainActor.run { Array(model.sessions.values) }
            return self.encoded(Payload(sessions: sessions))
        }

        await server.appendRoute("GET /api/permissions") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.operatorOK(request) else { return self.unauthorized }
            struct Payload: Encodable { let permissions: [PermissionRequest] }
            let pending = await MainActor.run { Array(model.pendingPermissions.values) }
            return self.encoded(Payload(permissions: pending))
        }

        await server.appendRoute("POST /api/permissions") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.machineOK(request) else { return self.unauthorized }
            guard let body = try? await request.bodyData,
                  let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: body)
            else { return self.json(["error": "bad envelope"], status: .badRequest) }
            guard let id = await MainActor.run(body: { model.createPermission(envelope) }) else {
                return self.json(["error": "missing machine, session_id or tool_name"], status: .badRequest)
            }
            return self.json(["id": id])
        }

        await server.appendRoute("GET /api/permissions/:id/decision?wait=:wait") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.machineOK(request) else { return self.unauthorized }
            guard let id = request.routeParameters["id"] else { return self.json(["error": "bad id"], status: .badRequest) }
            let wait = min(Int(request.routeParameters["wait"] ?? "0") ?? 0, 120)
            guard let (decision, reason) = await model.waitForDecision(id, waitSeconds: wait) else {
                return self.json(["error": "unknown permission id"], status: .notFound)
            }
            return self.json(["decision": decision, "reason": reason ?? ""])
        }

        await server.appendRoute("POST /api/permissions/:id/decide") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.operatorOK(request) else { return self.unauthorized }
            guard let id = request.routeParameters["id"],
                  let body = try? await request.bodyData,
                  let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let decision = parsed["decision"] as? String,
                  decision == "allow" || decision == "deny"
            else { return self.json(["error": #"decision must be "allow" or "deny""#], status: .badRequest) }
            let ok = await MainActor.run {
                model.localDecide(id, decision: decision, reason: parsed["reason"] as? String)
            }
            return ok ? self.json(["ok": true]) : self.json(["error": "unknown or already-decided id"], status: .conflict)
        }

        // One-liner remote install. The URL carries the OPERATOR token (only the host
        // can mint installers); the script it returns provisions the remote machine
        // with the MACHINE token — a compromised remote can never approve for others.
        await server.appendRoute("GET /install?token=:token") { [weak self] request in
            guard let self, Self.allowedSource(request), request.routeParameters["token"] == self.operatorToken else {
                return HTTPResponse(statusCode: .notFound)
            }
            let host = request.headers[HTTPHeader("Host")] ?? "localhost:\(self.port)"
            // Only the machine token reaches the remote — never the operator token.
            // The hook is inlined so the remote needs no second (token-bearing) fetch.
            let script = EmbeddedScripts.installScript
                .replacingOccurrences(of: "__HOOK_SCRIPT__", with: EmbeddedScripts.hookScript)
                .replacingOccurrences(of: "__SERVER__", with: "http://\(host)")
                .replacingOccurrences(of: "__TOKEN__", with: self.machineToken)
            return HTTPResponse(statusCode: .ok, headers: [HTTPHeader("Content-Type"): "text/plain"],
                                body: Data(script.utf8))
        }

        await server.appendRoute("GET /install/hook?token=:token") { [weak self] request in
            guard let self, Self.allowedSource(request), request.routeParameters["token"] == self.operatorToken else {
                return HTTPResponse(statusCode: .notFound)
            }
            return HTTPResponse(statusCode: .ok, headers: [HTTPHeader("Content-Type"): "text/plain"],
                                body: Data(EmbeddedScripts.hookScript.utf8))
        }
    }
}

// MARK: - Local (this Mac) hook setup — native, no jq needed

enum LocalSetup {
    private static let eventHooks = ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "Stop", "SessionEnd"]

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var isInstalled: Bool {
        (try? String(contentsOf: settingsURL, encoding: .utf8))?.contains("notch-hook") ?? false
    }

    static func install() throws {
        let fm = FileManager.default
        let notchDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".notch")
        try fm.createDirectory(at: notchDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        AppModel.ensureEnvFile()

        // Prefer the bundled dependency-free binary; fall back to the bash script in dev builds.
        let command: String
        if let bundled = Bundle.main.url(forResource: "notch-hook", withExtension: nil) {
            let dest = notchDir.appendingPathComponent("notch-hook")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: bundled, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            command = "\"$HOME/.notch/notch-hook\""
        } else {
            let dest = notchDir.appendingPathComponent("notch-hook.sh")
            try EmbeddedScripts.hookScript.write(to: dest, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            command = "\"$HOME/.notch/notch-hook.sh\""
        }

        // Fail closed: never overwrite an existing settings file we can't parse —
        // a malformed file could otherwise silently lose the user's other hooks.
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            try data.write(to: settingsURL.appendingPathExtension("notch-backup")) // raw backup first
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw NSError(domain: "notch", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.claude/settings.json is not valid JSON; left untouched (backup written)"
                ])
            }
            settings = parsed
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        func entry(mode: String, matcher: String? = nil, timeout: Int? = nil) -> [String: Any] {
            var hook: [String: Any] = ["type": "command", "command": "\(command) \(mode)"]
            if let timeout { hook["timeout"] = timeout }
            var result: [String: Any] = ["hooks": [hook]]
            if let matcher { result["matcher"] = matcher }
            return result
        }

        func stripped(_ value: Any?) -> [[String: Any]] {
            ((value as? [[String: Any]]) ?? []).filter { existing in
                let inner = existing["hooks"] as? [[String: Any]] ?? []
                return !inner.contains { (($0["command"] as? String) ?? "").contains("notch-hook") }
            }
        }

        for event in eventHooks {
            hooks[event] = stripped(hooks[event]) + [entry(mode: "event")]
        }
        hooks["PreToolUse"] = stripped(hooks["PreToolUse"])
            + [entry(mode: "permission", matcher: "Bash|Write|Edit|MultiEdit|ExitPlanMode", timeout: 60)]
            // AskUserQuestion isn't a permission (no allow/deny) — report it non-blocking so the notch alerts.
            + [entry(mode: "event", matcher: "AskUserQuestion")]
        settings["hooks"] = hooks

        let output = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: settingsURL)

        // Cursor uses its own hooks.json; only the compiled binary speaks its dialect.
        if command.contains("notch-hook\"") {
            try? installCursorHooks()
        }
    }

    /// Merge Notch entries into ~/.cursor/hooks.json (only if Cursor is present).
    private static func installCursorHooks() throws {
        let fm = FileManager.default
        let cursorDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
        guard fm.fileExists(atPath: cursorDir.path) else { return }
        let hooksURL = cursorDir.appendingPathComponent("hooks.json")
        let binary = fm.homeDirectoryForCurrentUser.appendingPathComponent(".notch/notch-hook").path

        // Fail closed like the Claude settings path: back up raw bytes and refuse to
        // overwrite an existing hooks.json we can't parse (would lose the user's hooks).
        var root: [String: Any] = ["version": 1]
        if let data = try? Data(contentsOf: hooksURL) {
            try data.write(to: hooksURL.appendingPathExtension("notch-backup"))
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw NSError(domain: "notch", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "~/.cursor/hooks.json is not valid JSON; left untouched (backup written)"
                ])
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        func stripped(_ value: Any?) -> [[String: Any]] {
            ((value as? [[String: Any]]) ?? []).filter {
                !((($0["command"] as? String) ?? "").contains("notch-hook"))
            }
        }

        for event in ["sessionStart", "beforeSubmitPrompt", "afterFileEdit", "postToolUse", "stop", "sessionEnd"] {
            hooks[event] = stripped(hooks[event]) + [["command": "\(binary) cursor-event"]]
        }
        hooks["beforeShellExecution"] = stripped(hooks["beforeShellExecution"])
            + [["command": "\(binary) cursor-shell", "timeout": 90]]

        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: hooksURL)
    }
}

// MARK: - "Add Remote Machine" one-liner

enum RemoteAdd {
    /// Remote access is Tailscale-only: the server rejects non-tailnet sources,
    /// so a LAN/public address in the command would never work anyway.
    /// The URL carries the operator token (which authorizes minting an installer);
    /// the returned script provisions the remote with only the machine token.
    static func command(operatorToken: String, port: UInt16) -> String? {
        guard let address = tailscaleAddress() else { return nil }
        return "curl -fsSL \"http://\(address):\(port)/install?token=\(operatorToken)\" | bash"
    }

    @discardableResult
    static func copyToClipboard(operatorToken: String, port: UInt16) -> Bool {
        guard let command = command(operatorToken: operatorToken, port: port) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        return true
    }

    static func tailscaleAddress() -> String? {
        for tailscale in ["/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"] {
            if let out = run(tailscale, ["ip", "-4"]) { return out }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").first.map(String.init)
        return (out?.isEmpty ?? true) ? nil : out
    }
}
