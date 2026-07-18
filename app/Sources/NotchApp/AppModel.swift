import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: String {
        case connecting, connected, disconnected
    }

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var pendingPermissions: [String: PermissionRequest] = [:]
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var serverDescription = ""
    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    /// Wired by AppDelegate to control the notch panel.
    var requestExpand: (() -> Void)?
    var requestCompact: (() -> Void)?
    var onAttention: ((_ hasAttention: Bool) -> Void)?

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

    /// Reads ~/.notch/env (same file the hooks use); falls back to local dev defaults.
    static func loadConfig() -> (server: String, token: String) {
        var values = ["NOTCH_SERVER": "http://localhost:4519", "NOTCH_TOKEN": "dev-token"]
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notch/env")
        if let text = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, !line.hasPrefix("#") else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if values.keys.contains(key) { values[key] = value }
            }
        }
        return (values["NOTCH_SERVER"]!, values["NOTCH_TOKEN"]!)
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
        components.queryItems = [URLQueryItem(name: "token", value: config.token)]
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
        // Optimistic removal; the server's permission_resolved broadcast confirms it.
        pendingPermissions.removeValue(forKey: id)
        let payload: [String: String] = [
            "type": "decide",
            "id": id,
            "decision": decision,
            "reason": "Decided via Notch app",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }
}
