import Foundation

/// Pure, dependency-free logic shared by the app and the hook binary, extracted
/// so it can be unit-tested without launching the server or the UI.

public enum SourceFilter {
    /// Mirrors the server's network policy: only loopback and the Tailscale tailnet
    /// (100.64.0.0/10, fd7a:115c:a1e0::/48) are allowed; LAN/internet are rejected.
    public static func isAllowed(ip: String?) -> Bool {
        guard let ip, !ip.isEmpty else { return false }
        let lower = ip.lowercased()
        if lower == "::1" { return true }
        if lower.hasPrefix("fd7a:115c:a1e0") { return true }
        let v4 = lower.hasPrefix("::ffff:") ? String(lower.dropFirst(7)) : lower
        if v4 == "127.0.0.1" { return true }
        let parts = v4.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1]!)
    }
}

public enum Version {
    /// Semantic-ish comparison used by the update notifier ("0.3.1" > "0.3.0").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum CursorTranslate {
    /// Maps Cursor's hook schema onto the Claude Code-shaped events the server speaks.
    /// Sessions are keyed by workspace (Cursor splits one chat across conversation ids).
    public static func translate(_ raw: [String: Any]) -> [String: Any] {
        var event: [String: Any] = [:]
        let workspace = (raw["workspace_roots"] as? [String])?.first
        event["session_id"] = workspace.map { "ws:\($0)" }
            ?? raw["conversation_id"] as? String ?? raw["session_id"] as? String ?? "cursor"
        event["cwd"] = workspace ?? raw["cwd"] as? String

        switch raw["hook_event_name"] as? String {
        case "sessionStart":
            event["hook_event_name"] = "SessionStart"
        case "beforeSubmitPrompt":
            event["hook_event_name"] = "UserPromptSubmit"
            event["prompt"] = raw["prompt"]
        case "afterFileEdit":
            event["hook_event_name"] = "PostToolUse"
            event["tool_name"] = "Edit"
            var toolInput: [String: Any] = ["file_path": raw["file_path"] ?? ""]
            if let first = (raw["edits"] as? [[String: Any]])?.first {
                toolInput["old_string"] = first["old_string"]
                toolInput["new_string"] = first["new_string"]
            }
            event["tool_input"] = toolInput
        case "preToolUse":
            event["hook_event_name"] = "PreToolUse"
            event["tool_name"] = raw["tool_name"]
            event["tool_input"] = raw["tool_input"]
        case "postToolUse":
            event["hook_event_name"] = "PostToolUse"
            event["tool_name"] = raw["tool_name"]
            event["tool_input"] = raw["tool_input"]
        case "beforeShellExecution":
            event["hook_event_name"] = "PreToolUse"
            event["tool_name"] = "Bash"
            event["tool_input"] = ["command": raw["command"] ?? ""]
        case "stop":
            event["hook_event_name"] = "Stop"
        case "sessionEnd":
            event["hook_event_name"] = "SessionEnd"
        default:
            event["hook_event_name"] = raw["hook_event_name"] ?? "unknown"
        }
        return event
    }
}
