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
    var cwd: String?
    var state: SessionState
    var lastTool: String?
    var lastMessage: String?
    var startedAt: Double
    var updatedAt: Double

    var id: String { key }
    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return String(sessionId.prefix(8)) }
        return (cwd as NSString).lastPathComponent
    }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

/// Minimal JSON tree, used for the arbitrary `tool_input` payload.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}

struct PermissionRequest: Codable, Identifiable, Equatable {
    let id: String
    let machine: String
    let sessionId: String
    let toolName: String
    let toolInput: JSONValue?
    let cwd: String?
    let createdAt: Double

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return String(sessionId.prefix(8)) }
        return (cwd as NSString).lastPathComponent
    }

    var isPlan: Bool { toolName == "ExitPlanMode" }

    /// The main thing to show the user: the command, file path, or plan text.
    var detail: String? {
        switch toolName {
        case "Bash": return toolInput?["command"]?.stringValue
        case "Write", "Edit", "MultiEdit": return toolInput?["file_path"]?.stringValue
        case "ExitPlanMode": return toolInput?["plan"]?.stringValue
        default: return nil
        }
    }

    var filePath: String? { toolInput?["file_path"]?.stringValue }

    /// Old/new lines for Edit requests, so the card can render a real diff.
    var editDiff: (removed: [String], added: [String])? {
        guard toolName == "Edit",
              let old = toolInput?["old_string"]?.stringValue,
              let new = toolInput?["new_string"]?.stringValue
        else { return nil }
        return (old.components(separatedBy: "\n"), new.components(separatedBy: "\n"))
    }

    /// Content lines for Write requests (all lines are additions).
    var writeContent: [String]? {
        guard toolName == "Write" else { return nil }
        return toolInput?["content"]?.stringValue?.components(separatedBy: "\n")
    }
}

/// What hooks POST to the server (both bash and compiled variants).
struct HookEnvelope: Decodable {
    let machine: String
    let agent: String?
    let event: HookEvent
}

struct HookEvent: Decodable {
    let session_id: String?
    let hook_event_name: String?
    let cwd: String?
    let prompt: String?
    let message: String?
    let tool_name: String?
    let tool_input: JSONValue?
}

struct ServerMessage: Decodable {
    let type: String
    let sessions: [Session]?
    let permissions: [PermissionRequest]?
    let session: Session?
    let request: PermissionRequest?
    let id: String?
    let decision: String?
    let key: String?
}
