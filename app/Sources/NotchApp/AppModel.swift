import AppKit
import Foundation
import NotchCore

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: String {
        case connecting, connected, disconnected
    }

    enum Mode {
        case hosting   // this app IS the server (default: NOTCH_SERVER is localhost)
        case client    // viewer of a server elsewhere (or an external local server)
    }

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var pendingPermissions: [String: PermissionRequest] = [:]
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var serverDescription = ""
    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    /// When on, the idle "your turn" ping (Claude finished a turn) also expands + alerts.
    @Published var notifyOnTurnDone: Bool = UserDefaults.standard.bool(forKey: "notifyOnTurnDone") {
        didSet { UserDefaults.standard.set(notifyOnTurnDone, forKey: "notifyOnTurnDone") }
    }
    @Published private(set) var mode: Mode = .client
    @Published private(set) var updateAvailable: (version: String, url: String)?

    var token = ""            // machine role
    var operatorToken = ""    // operator role (dashboard / decisions)
    private(set) var hostedPort: UInt16 = 4519
    private var embedded: EmbeddedServer?
    private var sweepTask: Task<Void, Never>?
    private var staleAfterMs: Double = 15 * 60 * 1000
    private var retainFinishedMs: Double = 6 * 60 * 60 * 1000
    private let permissionExpiryMs: Double = 90 * 1000
    // Hosting-mode bookkeeping (not part of the Session payload)
    private var sessionPendingIds: [String: [String]] = [:]
    private var decidedPermissions: [String: (decision: String, reason: String?, at: Double)] = [:]
    private var permissionWaiters: [String: [CheckedContinuation<(String, String?)?, Never>]] = [:]

    /// Wired by AppDelegate to control the notch panel.
    var requestExpand: (() -> Void)?
    var requestCompact: (() -> Void)?
    var onAttention: ((_ hasAttention: Bool) -> Void)?
    /// Fired after the user resolves a permission and nothing else needs them.
    var onAllResolved: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    // MARK: Derived state

    var visibleSessions: [Session] {
        sessions.values
            .filter { $0.state != .ended }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
    var attentionCount: Int { sessions.values.filter { $0.state.needsUser }.count }

    // MARK: Config

    /// Reads ~/.notch/env (same file the hooks use); falls back to local defaults.
    struct Config {
        var server: String
        var machineToken: String
        var operatorToken: String
        var staleMinutes: Double
        var retainHours: Double
    }

    static func loadConfig() -> Config {
        var values: [String: String] = [:]
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notch/env")
        if let text = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                values[key] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        let machine = values["NOTCH_TOKEN"] ?? ""
        return Config(
            server: values["NOTCH_SERVER"] ?? "http://localhost:4519",
            machineToken: machine,
            operatorToken: values["NOTCH_OPERATOR_TOKEN"] ?? machine,
            staleMinutes: Double(values["NOTCH_STALE_MINUTES"] ?? "") ?? 15,
            retainHours: Double(values["NOTCH_RETAIN_HOURS"] ?? "") ?? 6
        )
    }

    // MARK: Startup

    /// Zero-config entry point: ensure ~/.notch/env exists, then host locally by
    /// default — or act as a client when NOTCH_SERVER points elsewhere (or an
    /// external server already owns the port).
    func start() {
        Self.ensureEnvFile()
        let config = Self.loadConfig()
        token = config.machineToken
        operatorToken = config.operatorToken
        staleAfterMs = config.staleMinutes * 60 * 1000
        retainFinishedMs = config.retainHours * 60 * 60 * 1000
        serverDescription = config.server
        checkForUpdates()

        guard let url = URL(string: config.server),
              let host = url.host,
              ["localhost", "127.0.0.1"].contains(host)
        else {
            connect()
            return
        }

        let port = UInt16(url.port ?? 4519)
        hostedPort = port
        Task { @MainActor in
            if await Self.isHealthy(config.server) {
                self.connect() // an external server (e.g. headless Node) owns the port
                return
            }
            let server = EmbeddedServer(model: self, machineToken: config.machineToken,
                                        operatorToken: config.operatorToken, port: port)
            do {
                try await server.start()
                self.embedded = server
                self.mode = .hosting
                self.connection = .connected
                self.serverDescription = "hosting on :\(port)"
                self.startSweeps()
            } catch {
                self.connect()
            }
        }
    }

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static var notchDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notch")
    }

    /// Tighten ~/.notch to 0700 and env to 0600 so no other local account can read
    /// the tokens regardless of umask (findings: secret file permissions).
    nonisolated static func lockDownPermissions() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: notchDir.path)
        let env = notchDir.appendingPathComponent("env").path
        if fm.fileExists(atPath: env) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env)
        }
    }

    nonisolated static func ensureEnvFile() {
        let dir = notchDir
        let file = dir.appendingPathComponent("env")
        let fm = FileManager.default

        if fm.fileExists(atPath: file.path) {
            migrateOperatorToken(file)
            lockDownPermissions()
            return
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let hostname = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
        let content = """
        NOTCH_SERVER="http://localhost:4519"
        NOTCH_TOKEN="\(randomToken())"
        NOTCH_OPERATOR_TOKEN="\(randomToken())"
        NOTCH_MACHINE="\(hostname)"
        NOTCH_REMOTE_APPROVE=1
        """
        try? content.write(to: file, atomically: true, encoding: .utf8)
        lockDownPermissions()
    }

    /// Existing installs predate the operator token — add one so this host can
    /// decide while remote machines keep only the (machine) NOTCH_TOKEN.
    private nonisolated static func migrateOperatorToken(_ file: URL) {
        guard var text = try? String(contentsOf: file, encoding: .utf8),
              !text.contains("NOTCH_OPERATOR_TOKEN")
        else { return }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "NOTCH_OPERATOR_TOKEN=\"\(randomToken())\"\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Updates

    private static let githubRepo = "MinhTamCK/notch"

    /// Checks the newest GitHub release; sets `updateAvailable` when it beats the
    /// running version. Silently a no-op while the repo is private (API 404s).
    func checkForUpdates() {
        Task { [weak self] in
            guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = json["html_url"] as? String
            else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if Self.isNewer(latest, than: current) {
                await MainActor.run { self?.updateAvailable = (latest, page) }
            }
        }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        NotchCore.Version.isNewer(a, than: b)
    }

    nonisolated static func isHealthy(_ server: String) async -> Bool {
        guard let url = URL(string: server + "/health") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 1)
        req.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Connection

    func connect() {
        reconnectTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        let config = Self.loadConfig()
        serverDescription = config.server
        guard var components = URLComponents(string: config.server) else {
            connection = .disconnected
            retryConnectLater()
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        // The dashboard WebSocket is an operator right.
        components.queryItems = [URLQueryItem(name: "token", value: config.operatorToken)]
        guard let url = components.url else {
            connection = .disconnected
            retryConnectLater()
            return
        }

        connection = .connecting
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(on: socket)

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, self.task === socket else { return }
                socket.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in self?.scheduleReconnect(for: socket) }
                    }
                }
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === socket else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect(for: socket)
                case .success(let message):
                    self.connection = .connected
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: socket)
                }
            }
        }
    }

    /// Retries connect() when config was unusable — self-heals once ~/.notch/env is fixed.
    private func retryConnectLater() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func scheduleReconnect(for socket: URLSessionWebSocketTask) {
        guard task === socket else { return }
        task = nil
        pingTask?.cancel()
        connection = .disconnected
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: Message handling

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ServerMessage.self, from: data)
        else { return }

        switch message.type {
        case "snapshot":
            sessions = Dictionary(uniqueKeysWithValues: (message.sessions ?? []).map { ($0.key, $0) })
            pendingPermissions = Dictionary(uniqueKeysWithValues: (message.permissions ?? []).map { ($0.id, $0) })
            // Alert (not just expand) so attention that arrived while disconnected isn't silent.
            if attentionCount > 0 {
                alert()
            } else {
                onAttention?(false)
            }
        case "session":
            guard let session = message.session else { return }
            let previous = sessions[session.key]?.state
            sessions[session.key] = session
            if session.state.needsUser, previous != session.state {
                alert()
            } else if !session.state.needsUser, attentionCount == 0 {
                onAttention?(false)
            }
        case "permission":
            guard let request = message.request else { return }
            pendingPermissions[request.id] = request
        case "permission_resolved":
            guard let id = message.id else { return }
            pendingPermissions.removeValue(forKey: id)
        case "session_removed":
            guard let key = message.key else { return }
            sessions.removeValue(forKey: key)
        default:
            break
        }
    }

    private func alert() {
        if soundEnabled { NSSound(named: "Glass")?.play() }
        onAttention?(true)
    }

    // MARK: Decisions

    func decide(_ id: String, decision: String) {
        if mode == .hosting {
            _ = localDecide(id, decision: decision, reason: "Decided via Notch app")
        } else {
            // Client mode: optimistic removal; the server's broadcast confirms it.
            pendingPermissions.removeValue(forKey: id)
            let payload: [String: String] = [
                "type": "decide",
                "id": id,
                "decision": decision,
                "reason": "Decided via Notch app",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: data, encoding: .utf8) {
                task?.send(.string(text)) { _ in }
            }
        }
        // The user just cleared the last thing needing them — let the panel tuck away.
        if pendingPermissions.isEmpty && attentionCount == 0 {
            onAllResolved?()
        }
    }

    // MARK: - Hosting-mode store (port of the Node server's state machine)

    private func trunc(_ s: String?, _ n: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > n ? String(s.prefix(n)) + "…" : s
    }

    /// Slash-command invocations arrive as XML-ish wrappers; show the command itself.
    private func cleanPrompt(_ p: String?) -> String? {
        guard let p else { return nil }
        if let cmdRange = p.range(of: "<command-name>([^<]+)</command-name>", options: .regularExpression) {
            let cmd = String(p[cmdRange]).replacingOccurrences(of: "<command-name>", with: "")
                .replacingOccurrences(of: "</command-name>", with: "").trimmingCharacters(in: .whitespaces)
            var args = ""
            if let argRange = p.range(of: "<command-args>([^<]*)</command-args>", options: .regularExpression) {
                args = String(p[argRange]).replacingOccurrences(of: "<command-args>", with: "")
                    .replacingOccurrences(of: "</command-args>", with: "").trimmingCharacters(in: .whitespaces)
            }
            return trunc("\(cmd) \(args)".trimmingCharacters(in: .whitespaces), 200)
        }
        return trunc(p, 200)
    }

    private func describeTool(_ name: String, _ input: JSONValue?) -> String {
        switch name {
        case "Bash": return trunc("$ \(input?["command"]?.stringValue ?? "")", 120) ?? name
        case "Write", "Edit", "MultiEdit": return trunc("\(name) \(input?["file_path"]?.stringValue ?? "")", 120) ?? name
        case "ExitPlanMode": return "Plan ready for review"
        default: return name
        }
    }

    /// Turns an AskUserQuestion payload into a one-line "question · optA / optB" summary.
    private func describeQuestion(_ input: JSONValue?) -> String? {
        guard let first = input?["questions"]?.arrayValue?.first else { return nil }
        let q = first["question"]?.stringValue ?? first["header"]?.stringValue ?? "Question"
        let opts = (first["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
        let summary = opts.isEmpty ? q : "\(q) · \(opts.prefix(4).joined(separator: " / "))"
        return trunc(summary, 300)
    }

    private func hasPendingPermission(_ key: String) -> Bool {
        (sessionPendingIds[key] ?? []).contains { pendingPermissions[$0] != nil }
    }

    private func upsertSession(_ env: HookEnvelope) -> String? {
        guard let sid = env.event.session_id else { return nil }
        let key = "\(env.machine):\(sid)"
        if sessions[key] == nil {
            sessions[key] = Session(
                key: key, machine: env.machine, sessionId: sid,
                agent: env.agent ?? "claude-code", cwd: env.event.cwd,
                state: .working, lastTool: nil, lastMessage: nil,
                startedAt: Date().timeIntervalSince1970 * 1000,
                updatedAt: Date().timeIntervalSince1970 * 1000
            )
        }
        if let cwd = env.event.cwd { sessions[key]?.cwd = cwd }
        return key
    }

    func applyEnvelope(_ env: HookEnvelope) -> Bool {
        // Terminal events for sessions we never saw are noise (e.g. Cursor emits
        // stop under a different conversation id) — never materialize a row from them.
        if let sid = env.event.session_id,
           sessions["\(env.machine):\(sid)"] == nil,
           ["Stop", "SessionEnd"].contains(env.event.hook_event_name ?? "") {
            return true
        }
        guard let key = upsertSession(env), var s = sessions[key] else { return false }
        let previous = s.state
        switch env.event.hook_event_name {
        case "SessionStart":
            s.state = .working
        case "UserPromptSubmit":
            s.state = .working
            s.lastMessage = cleanPrompt(env.event.prompt)
        case "PreToolUse" where env.event.tool_name == "AskUserQuestion":
            // Claude is asking you to pick an option — it's waiting on you, not "working".
            s.state = .needsAttention
            s.lastMessage = describeQuestion(env.event.tool_input) ?? "Claude is asking you a question"
        case "PreToolUse", "PostToolUse":
            if !hasPendingPermission(key) { s.state = .working }
            if let tool = env.event.tool_name { s.lastTool = describeTool(tool, env.event.tool_input) }
        case "Notification":
            let msg = env.event.message ?? ""
            // "waiting for your input" is the idle "your turn" ping. Treat it as an
            // alert only when the user opted in; otherwise mark the turn done.
            let isIdle = msg.lowercased().contains("waiting for your input")
            if !hasPendingPermission(key) {
                s.state = (isIdle && !notifyOnTurnDone) ? .done : .needsAttention
            }
            s.lastMessage = trunc(msg, 300)
        case "Stop":
            s.state = .done
        case "SessionEnd":
            s.state = .ended
        default:
            break
        }
        s.updatedAt = Date().timeIntervalSince1970 * 1000
        sessions[key] = s
        sessionStateChanged(from: previous, to: s.state)
        return true
    }

    func createPermission(_ env: HookEnvelope) -> String? {
        guard let toolName = env.event.tool_name,
              let key = upsertSession(env),
              var s = sessions[key]
        else { return nil }
        let previous = s.state
        let request = PermissionRequest(
            id: UUID().uuidString.lowercased(),
            machine: env.machine,
            sessionId: s.sessionId,
            agent: env.agent ?? "claude-code",
            toolName: toolName,
            toolInput: env.event.tool_input,
            cwd: env.event.cwd,
            createdAt: Date().timeIntervalSince1970 * 1000
        )
        pendingPermissions[request.id] = request
        sessionPendingIds[key, default: []].append(request.id)
        s.state = .needsPermission
        s.lastTool = describeTool(toolName, env.event.tool_input)
        s.updatedAt = Date().timeIntervalSince1970 * 1000
        sessions[key] = s
        sessionStateChanged(from: previous, to: s.state)
        return request.id
    }

    @discardableResult
    func localDecide(_ id: String, decision: String, reason: String?) -> Bool {
        guard let request = pendingPermissions.removeValue(forKey: id) else { return false }
        decidedPermissions[id] = (decision, reason, Date().timeIntervalSince1970 * 1000)

        let key = "\(request.machine):\(request.sessionId)"
        sessionPendingIds[key]?.removeAll { $0 == id }
        if var s = sessions[key], s.state == .needsPermission, !hasPendingPermission(key) {
            // On timeout the hook falls back to the terminal prompt, so the user is needed there.
            s.state = decision == "timeout" ? .needsAttention : .working
            s.updatedAt = Date().timeIntervalSince1970 * 1000
            sessions[key] = s
            if attentionCount == 0 { onAttention?(false) }
        }

        for waiter in permissionWaiters.removeValue(forKey: id) ?? [] {
            waiter.resume(returning: (decision, reason))
        }
        return true
    }

    /// Long-poll support for hooks. Returns nil for unknown ids.
    func waitForDecision(_ id: String, waitSeconds: Int) async -> (String, String?)? {
        if let done = decidedPermissions[id] { return (done.decision, done.reason) }
        guard pendingPermissions[id] != nil else { return nil }
        return await withCheckedContinuation { continuation in
            permissionWaiters[id, default: []].append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(waitSeconds))
                guard let self, self.pendingPermissions[id] != nil else { return }
                self.localDecide(id, decision: "timeout", reason: "No decision before hook timeout")
            }
        }
    }

    private func sessionStateChanged(from previous: SessionState, to state: SessionState) {
        if state.needsUser, previous != state {
            alert()
        } else if !state.needsUser, attentionCount == 0 {
            onAttention?(false)
        }
    }

    private func startSweeps() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.sweep()
            }
        }
    }

    private func sweep() {
        let now = Date().timeIntervalSince1970 * 1000
        // Expire abandoned permission requests (hook died before long-polling).
        for (id, request) in pendingPermissions where request.createdAt < now - permissionExpiryMs {
            localDecide(id, decision: "timeout", reason: "Expired unanswered")
        }
        for (id, done) in decidedPermissions where done.at < now - 5 * 60 * 1000 {
            decidedPermissions.removeValue(forKey: id)
        }
        for (key, var s) in sessions {
            if s.state.needsUser || s.state == .working, s.updatedAt < now - staleAfterMs {
                s.state = .stale
                s.updatedAt = now
                sessions[key] = s
            } else if !(s.state.needsUser || s.state == .working), s.updatedAt < now - retainFinishedMs {
                sessions.removeValue(forKey: key)
                sessionPendingIds.removeValue(forKey: key)
            }
        }
    }
}
