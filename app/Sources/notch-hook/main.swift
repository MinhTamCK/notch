// Dependency-free Claude Code hook for macOS (replaces the bash+jq script locally).
//   notch-hook event       — fire-and-forget: report the hook event to the server
//   notch-hook permission  — PreToolUse: ask the server for an allow/deny decision
// Fails open on every path: any error exits 0 with no output so Claude Code
// falls back to its normal terminal flow.
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

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let event = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] else { exit(0) }

let envelope: [String: Any] = [
    "machine": machine,
    "agent": "claude-code",
    "ts": Int(Date().timeIntervalSince1970 * 1000),
    "event": event,
]

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

// Respect the session's permission mode: only gate tools Claude Code itself would prompt for.
var effectiveMode = mode
if mode == "permission" {
    let pm = event["permission_mode"] as? String ?? "default"
    let tool = event["tool_name"] as? String ?? ""
    if ["bypassPermissions", "auto", "dontAsk"].contains(pm) { effectiveMode = "event" }
    if pm == "acceptEdits", ["Edit", "Write", "MultiEdit"].contains(tool) { effectiveMode = "event" }
    if remoteApprove == "0" { effectiveMode = "event" }
}

if effectiveMode == "permission" {
    guard let created = request("POST", "/api/permissions", body: envelope, timeout: 3),
          let id = created["id"] as? String
    else { exit(0) }
    guard let decided = request("GET", "/api/permissions/\(id)/decision?wait=55", body: nil, timeout: 58),
          let decision = decided["decision"] as? String,
          decision == "allow" || decision == "deny"
    else { exit(0) }
    let output: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": decided["reason"] as? String ?? "Decided via Notch",
        ],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

_ = request("POST", "/api/events", body: envelope, timeout: 2)
exit(0)
