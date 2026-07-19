// Dependency-free agent hook for macOS (replaces the bash+jq script locally).
//   notch-hook event         — Claude Code: fire-and-forget event report
//   notch-hook permission    — Claude Code PreToolUse: allow/deny gate (long-poll)
//   notch-hook cursor-event  — Cursor: translate + report event
//   notch-hook cursor-shell  — Cursor beforeShellExecution: allow/deny/ask gate
// Fails safe on every path: Claude Code falls back to its terminal prompt;
// Cursor gets an explicit {"permission":"ask"} (it fails OPEN otherwise).
import Foundation

func loadEnvFile() -> [String: String] {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notch/env")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        values[parts[0].trimmingCharacters(in: .whitespaces)] =
            parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }
    return values
}

let envFile = loadEnvFile()
func cfg(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? envFile[key] ?? fallback
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "event"
let server = cfg("NOTCH_SERVER", "http://localhost:4519")
let token = cfg("NOTCH_TOKEN", "dev-token")
let machine = cfg("NOTCH_MACHINE", String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac"))
let remoteApprove = cfg("NOTCH_REMOTE_APPROVE", "1")
let isCursor = mode.hasPrefix("cursor")

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object) {
        FileHandle.standardOutput.write(data)
    }
}

func request(_ method: String, _ path: String, body: [String: Any]?, timeout: TimeInterval) -> [String: Any]? {
    guard let url = URL(string: server + path) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    let semaphore = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    URLSession.shared.dataTask(with: req) { data, response, _ in
        if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
            result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 2)
    return result
}

/// Map Cursor's hook schema onto the Claude Code-shaped events the server speaks.
/// Cursor splits one chat across multiple conversation ids (outer chat for
/// prompt/stop, inner loop for tools), so we key sessions by WORKSPACE instead —
/// one row per project, which is also how you think about Cursor.
func translateCursor(_ raw: [String: Any]) -> [String: Any] {
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

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// NOTCH_DEBUG=1 in ~/.notch/env dumps raw payloads for diagnosing agent quirks.
if cfg("NOTCH_DEBUG", "0") == "1" {
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notch/hook-debug.log")
    let line = "[\(mode)] " + (String(data: stdinData, encoding: .utf8) ?? "?") + "\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
    // Raw payloads may contain prompts/commands — keep the log owner-only.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
}

guard let raw = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] else { exit(0) }

// Cursor background/auxiliary agents are noise in the session list.
if isCursor, raw["is_background_agent"] as? Bool == true { exit(0) }

let event = isCursor ? translateCursor(raw) : raw

let envelope: [String: Any] = [
    "machine": machine,
    "agent": isCursor ? "cursor" : "claude-code",
    "ts": Int(Date().timeIntervalSince1970 * 1000),
    "event": event,
]

func gate() -> (decision: String, reason: String)? {
    guard let created = request("POST", "/api/permissions", body: envelope, timeout: 3),
          let id = created["id"] as? String,
          let decided = request("GET", "/api/permissions/\(id)/decision?wait=55", body: nil, timeout: 58),
          let decision = decided["decision"] as? String,
          decision == "allow" || decision == "deny"
    else { return nil }
    return (decision, decided["reason"] as? String ?? "Decided via Notch")
}

switch mode {
case "permission":
    // Respect Claude Code's permission mode: only gate tools it would prompt for.
    let pm = raw["permission_mode"] as? String ?? "default"
    let tool = raw["tool_name"] as? String ?? ""
    let skip = ["bypassPermissions", "auto", "dontAsk"].contains(pm)
        || (pm == "acceptEdits" && ["Edit", "Write", "MultiEdit"].contains(tool))
        || remoteApprove == "0"
    if skip {
        _ = request("POST", "/api/events", body: envelope, timeout: 2)
        exit(0)
    }
    guard let (decision, reason) = gate() else { exit(0) } // silent → terminal prompt
    emit(["hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    ]])

case "cursor-shell":
    if remoteApprove == "0" {
        _ = request("POST", "/api/events", body: envelope, timeout: 2)
        exit(0) // no output: don't interfere with Cursor's own flow
    }
    if let (decision, reason) = gate() {
        if decision == "allow" {
            emit(["permission": "allow"])
        } else {
            emit(["permission": "deny", "user_message": reason, "agent_message": reason])
        }
    } else {
        // Cursor fails OPEN on hook errors — hand back to its own prompt instead.
        emit(["permission": "ask"])
    }

default: // event, cursor-event
    _ = request("POST", "/api/events", body: envelope, timeout: 2)
}
exit(0)
