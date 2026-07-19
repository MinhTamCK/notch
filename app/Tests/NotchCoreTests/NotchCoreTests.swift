import Testing
@testable import NotchCore

@Suite("SourceFilter — network policy")
struct SourceFilterTests {
    @Test func allowsLoopback() {
        #expect(SourceFilter.isAllowed(ip: "127.0.0.1"))
        #expect(SourceFilter.isAllowed(ip: "::1"))
        #expect(SourceFilter.isAllowed(ip: "::ffff:127.0.0.1"))
    }

    @Test func allowsTailscaleRange() {
        #expect(SourceFilter.isAllowed(ip: "100.64.0.1"))
        #expect(SourceFilter.isAllowed(ip: "100.82.132.78"))   // the real VM
        #expect(SourceFilter.isAllowed(ip: "100.127.255.255"))
        #expect(SourceFilter.isAllowed(ip: "fd7a:115c:a1e0::1"))
    }

    @Test func rejectsLanAndPublic() {
        #expect(!SourceFilter.isAllowed(ip: "192.168.1.10"))
        #expect(!SourceFilter.isAllowed(ip: "10.0.0.5"))
        #expect(!SourceFilter.isAllowed(ip: "8.8.8.8"))
        #expect(!SourceFilter.isAllowed(ip: "100.63.255.255"))  // just below /10
        #expect(!SourceFilter.isAllowed(ip: "100.128.0.0"))     // just above /10
    }

    @Test func rejectsMalformed() {
        #expect(!SourceFilter.isAllowed(ip: nil))
        #expect(!SourceFilter.isAllowed(ip: ""))
        #expect(!SourceFilter.isAllowed(ip: "not-an-ip"))
        #expect(!SourceFilter.isAllowed(ip: "100.64"))
        #expect(!SourceFilter.isAllowed(ip: "100.999.0.1"))
    }
}

@Suite("RoleAuth — token authorization")
struct RoleAuthTests {
    let machine = "machine-secret-123456"
    let op = "operator-secret-654321"

    @Test func operatorMayDoEverything() {
        #expect(RoleAuth.allows(bearer: "Bearer \(op)", requiresOperator: false, machineToken: machine, operatorToken: op))
        #expect(RoleAuth.allows(bearer: "Bearer \(op)", requiresOperator: true, machineToken: machine, operatorToken: op))
    }

    @Test func machineMayNotDoOperatorActions() {
        #expect(RoleAuth.allows(bearer: "Bearer \(machine)", requiresOperator: false, machineToken: machine, operatorToken: op))
        #expect(!RoleAuth.allows(bearer: "Bearer \(machine)", requiresOperator: true, machineToken: machine, operatorToken: op))
    }

    @Test func rejectsWrongMissingBlank() {
        #expect(!RoleAuth.allows(bearer: "Bearer wrong", requiresOperator: false, machineToken: machine, operatorToken: op))
        #expect(!RoleAuth.allows(bearer: nil, requiresOperator: false, machineToken: machine, operatorToken: op))
        #expect(!RoleAuth.allows(bearer: "Bearer ", requiresOperator: false, machineToken: machine, operatorToken: op))
        #expect(!RoleAuth.allows(bearer: "Bearer x", requiresOperator: true, machineToken: "", operatorToken: ""))
    }
}

@Suite("Version comparison")
struct VersionTests {
    @Test func newer() {
        #expect(Version.isNewer("0.3.1", than: "0.3.0"))
        #expect(Version.isNewer("0.4.0", than: "0.3.9"))
        #expect(Version.isNewer("1.0.0", than: "0.9.9"))
    }

    @Test func notNewer() {
        #expect(!Version.isNewer("0.3.0", than: "0.3.0"))
        #expect(!Version.isNewer("0.3.0", than: "0.3.1"))
        #expect(!Version.isNewer("0.2.9", than: "0.3.0"))
    }
}

@Suite("Cursor event translation")
struct CursorTranslateTests {
    @Test func keysSessionByWorkspace() {
        let out = CursorTranslate.translate([
            "conversation_id": "abc",
            "hook_event_name": "sessionStart",
            "workspace_roots": ["/Users/tam/proj"],
        ])
        #expect(out["session_id"] as? String == "ws:/Users/tam/proj")
        #expect(out["hook_event_name"] as? String == "SessionStart")
    }

    @Test func mapsShellToBashPreToolUse() {
        let out = CursorTranslate.translate([
            "hook_event_name": "beforeShellExecution",
            "command": "npm test",
            "workspace_roots": ["/w"],
        ])
        #expect(out["hook_event_name"] as? String == "PreToolUse")
        #expect(out["tool_name"] as? String == "Bash")
        let input = out["tool_input"] as? [String: Any]
        #expect(input?["command"] as? String == "npm test")
    }

    @Test func mapsFileEditWithDiff() {
        let out = CursorTranslate.translate([
            "hook_event_name": "afterFileEdit",
            "file_path": "/w/a.ts",
            "edits": [["old_string": "a", "new_string": "b"]],
            "workspace_roots": ["/w"],
        ])
        #expect(out["tool_name"] as? String == "Edit")
        let input = out["tool_input"] as? [String: Any]
        #expect(input?["old_string"] as? String == "a")
        #expect(input?["new_string"] as? String == "b")
    }
}
