import AppKit
import FlyingFox
import Foundation

/// The in-app server: hooks (local and remote) POST here; the UI updates directly.
/// Same HTTP API as the optional headless Node server, minus the WebSocket.
final class EmbeddedServer {
    private let model: AppModel
    private let token: String
    private let port: UInt16
    private let server: HTTPServer
    private var runTask: Task<Void, Never>?

    init(model: AppModel, token: String, port: UInt16) {
        self.model = model
        self.token = token
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

    private func authorized(_ request: HTTPRequest) -> Bool {
        request.headers[HTTPHeader("Authorization")] == "Bearer \(token)"
    }

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

        await server.appendRoute("GET /health") { _ in
            HTTPResponse(statusCode: .ok, headers: [HTTPHeader("Content-Type"): "application/json"],
                         body: Data(#"{"ok":true}"#.utf8))
        }

        await server.appendRoute("POST /api/events") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.authorized(request) else { return self.unauthorized }
            guard let body = try? await request.bodyData,
                  let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: body)
            else { return self.json(["error": "bad envelope"], status: .badRequest) }
            let ok = await MainActor.run { model.applyEnvelope(envelope) }
            return ok ? self.json(["ok": true]) : self.json(["error": "missing machine or session_id"], status: .badRequest)
        }

        await server.appendRoute("GET /api/sessions") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.authorized(request) else { return self.unauthorized }
            struct Payload: Encodable { let sessions: [Session] }
            let sessions = await MainActor.run { Array(model.sessions.values) }
            return self.encoded(Payload(sessions: sessions))
        }

        await server.appendRoute("GET /api/permissions") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.authorized(request) else { return self.unauthorized }
            struct Payload: Encodable { let permissions: [PermissionRequest] }
            let pending = await MainActor.run { Array(model.pendingPermissions.values) }
            return self.encoded(Payload(permissions: pending))
        }

        await server.appendRoute("POST /api/permissions") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.authorized(request) else { return self.unauthorized }
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
            guard self.authorized(request) else { return self.unauthorized }
            guard let id = request.routeParameters["id"] else { return self.json(["error": "bad id"], status: .badRequest) }
            let wait = min(Int(request.routeParameters["wait"] ?? "0") ?? 0, 120)
            guard let (decision, reason) = await model.waitForDecision(id, waitSeconds: wait) else {
                return self.json(["error": "unknown permission id"], status: .notFound)
            }
            return self.json(["decision": decision, "reason": reason ?? ""])
        }

        await server.appendRoute("POST /api/permissions/:id/decide") { [weak self] request in
            guard let self else { return HTTPResponse(statusCode: .serviceUnavailable) }
            guard self.authorized(request) else { return self.unauthorized }
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

        // One-liner remote install: curl -fsSL "http://<mac>:4519/install?token=…" | bash
        await server.appendRoute("GET /install?token=:token") { [weak self] request in
            guard let self, request.routeParameters["token"] == self.token else {
                return HTTPResponse(statusCode: .notFound)
            }
            let host = request.headers[HTTPHeader("Host")] ?? "localhost:\(self.port)"
            let script = EmbeddedScripts.installScript
                .replacingOccurrences(of: "__SERVER__", with: "http://\(host)")
                .replacingOccurrences(of: "__TOKEN__", with: self.token)
            return HTTPResponse(statusCode: .ok, headers: [HTTPHeader("Content-Type"): "text/plain"],
                                body: Data(script.utf8))
        }

        await server.appendRoute("GET /install/hook?token=:token") { [weak self] request in
            guard let self, request.routeParameters["token"] == self.token else {
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

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = parsed
            try? data.write(to: settingsURL.appendingPathExtension("notch-backup"))
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

        var root: [String: Any] = ["version": 1]
        if let data = try? Data(contentsOf: hooksURL),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
            try? data.write(to: hooksURL.appendingPathExtension("notch-backup"))
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
    static func command(token: String, port: UInt16) -> String {
        let address = detectAddress()
            ?? "\(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac").local"
        return "curl -fsSL \"http://\(address):\(port)/install?token=\(token)\" | bash"
    }

    static func copyToClipboard(token: String, port: UInt16) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command(token: token, port: port), forType: .string)
    }

    /// Prefer the Tailscale address (works across networks), else the LAN IP.
    private static func detectAddress() -> String? {
        for tailscale in ["/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"] {
            if let out = run(tailscale, ["ip", "-4"]) { return out }
        }
        return run("/usr/sbin/ipconfig", ["getifaddr", "en0"]) ?? run("/usr/sbin/ipconfig", ["getifaddr", "en1"])
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
