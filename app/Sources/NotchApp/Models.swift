import Foundation

enum SessionState: String, Codable {
    case working
    case needsPermission = "needs_permission"
    case needsAttention = "needs_attention"
    case done
    case ended
    case stale

    var needsUser: Bool { self == .needsPermission || self == .needsAttention }
}

struct Session: Codable, Identifiable, Equatable {
    let key: String
    let machine: String
    let sessionId: String
    let agent: String
    let cwd: String?
    let state: SessionState
    let lastTool: String?
    let lastMessage: String?
    let startedAt: Double
    let updatedAt: Double
    let pendingPermissionId: String?

    var id: String { key }
    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return String(sessionId.prefix(8)) }
        return (cwd as NSString).lastPathComponent
    }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

struct PermissionRequest: Codable, Identifiable, Equatable {
    let id: String
    let machine: String
    let sessionId: String
    let toolName: String
    let cwd: String?
    let createdAt: Double
}

struct ServerMessage: Decodable {
    let type: String
    let sessions: [Session]?
    let permissions: [PermissionRequest]?
    let session: Session?
    let request: PermissionRequest?
    let id: String?
    let decision: String?
}
