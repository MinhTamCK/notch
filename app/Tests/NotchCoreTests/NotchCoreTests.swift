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
        #expect(SourceFilter.isAllowed(ip: "100.100.100.100")) // mid-range tailnet address
        #expect(SourceFilter.isAllowed(ip: "100.127.255.255"))
        #expect(SourceFilter.isAllowed(ip: "fd7a:115c:a1e0::1"))
    }

    @Test func rejectsLanAndPublic() {
        #expect(!SourceFilter.isAllowed(ip: "192.168.1.100"))
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

@Suite("PatchSummary — Codex apply_patch")
struct PatchSummaryTests {
    let patch = """
    *** Begin Patch
    *** Update File: src/main.swift
    @@ func run() {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
    *** Add File: docs/NEW.md
    +# New
    *** Delete File: old.txt
    *** End Patch
    """

    @Test func extractsFilesAndLines() {
        let result = PatchSummary.parse(patch)
        #expect(result.files == [
            .init(op: .update, path: "src/main.swift"),
            .init(op: .add, path: "docs/NEW.md"),
            .init(op: .delete, path: "old.txt"),
        ])
        #expect(result.removed == ["let b = 2"])
        #expect(result.added == ["let b = 3", "let c = 4", "# New"])
    }

    @Test func describesFirstFileAndCount() {
        #expect(PatchSummary.describe(patch) == "Update src/main.swift (+2 files)")
        #expect(PatchSummary.describe("*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch") == "Add a.txt")
        #expect(PatchSummary.describe("not a patch") == nil)
    }
}

@Suite("Fleet — colour, order, grouping")
struct FleetTests {
    struct S { let machine: String; let state: String; let updatedAt: Double; let name: String }

    @Test func paletteMatchesDashboard() {
        #expect(Fleet.palette("working") == (0x8B93A1, 1))
        #expect(Fleet.palette("needs_permission") == (0xF5A524, 1))
        #expect(Fleet.palette("needs_attention") == (0xA78BFA, 1))
        #expect(Fleet.palette("done") == (0x3ECF8E, 1))
        #expect(Fleet.palette("stale") == (0x4A5060, 0.55))
        #expect(Fleet.palette("ended") == (0x343843, 0.45))
        #expect(Fleet.palette("something-new").hex == 0x8B93A1) // unknown stays grey
    }

    @Test func stateOutranksRecency() {
        let items = [
            S(machine: "m", state: "working", updatedAt: 900, name: "newer-working"),
            S(machine: "m", state: "done", updatedAt: 950, name: "newest-done"),
            S(machine: "m", state: "needs_permission", updatedAt: 100, name: "older-perm"),
            S(machine: "m", state: "needs_attention", updatedAt: 200, name: "attn"),
        ]
        let sorted = Fleet.sorted(items, state: \.state, updatedAt: \.updatedAt).map(\.name)
        #expect(sorted == ["older-perm", "attn", "newer-working", "newest-done"])
    }

    @Test func sameStateNewestFirst() {
        let items = [
            S(machine: "m", state: "working", updatedAt: 1, name: "old"),
            S(machine: "m", state: "working", updatedAt: 3, name: "new"),
            S(machine: "m", state: "working", updatedAt: 2, name: "mid"),
        ]
        #expect(Fleet.sorted(items, state: \.state, updatedAt: \.updatedAt).map(\.name) == ["new", "mid", "old"])
    }

    @Test func groupsByMachineAlphabetically() {
        let items = [
            S(machine: "panda", state: "working", updatedAt: 5, name: "giz"),
            S(machine: "nuc", state: "done", updatedAt: 9, name: "vi"),
            S(machine: "nuc", state: "needs_attention", updatedAt: 1, name: "sam"),
            S(machine: "mac-home", state: "working", updatedAt: 2, name: "notch"),
        ]
        let groups = Fleet.grouped(items, machine: \.machine, state: \.state, updatedAt: \.updatedAt)
        #expect(groups.map(\.machine) == ["mac-home", "nuc", "panda"])
        #expect(groups[1].items.map(\.name) == ["sam", "vi"])
    }

    @Test func ageFormatting() {
        #expect(Fleet.age(sinceMs: 0, nowMs: 20_000) == "20s")
        #expect(Fleet.age(sinceMs: 0, nowMs: 50 * 60_000) == "50m")
        #expect(Fleet.age(sinceMs: 0, nowMs: 3 * 3_600_000) == "3h")
        #expect(Fleet.age(sinceMs: 0, nowMs: 2 * 86_400_000) == "2d")
        #expect(Fleet.age(sinceMs: 5_000, nowMs: 0) == "0s") // clock skew never goes negative
    }
}

@Suite("Sprite — pixel mascot")
struct SpriteTests {
    func has(_ pixels: [Sprite.Pixel], _ x: Int, _ y: Int, _ role: Sprite.Role) -> Bool {
        pixels.contains { $0.x == x && $0.y == y && $0.role == role }
    }

    @Test func staysInsideGrid() {
        for state in Fleet.order {
            for frame in 0..<4 {
                for p in Sprite.pixels(state: state, frame: frame) {
                    #expect((0..<Sprite.width).contains(p.x) && (0..<Sprite.height).contains(p.y))
                }
            }
        }
    }

    @Test func workingAnimates() {
        let frames = (0..<4).map { Sprite.pixels(state: "working", frame: $0) }
        #expect(frames[0] != frames[1])            // legs alternate + bob
        #expect(frames[0] != frames[2])            // eyes shift
        #expect(Sprite.pixels(state: "working", frame: 4) == frames[0]) // 4-beat loop
    }

    @Test func permissionShowsExclamation() {
        let p = Sprite.pixels(state: "needs_permission", frame: 0)
        // "!" column above the right claw (JS y -3…-1 and 1 → grid 2…4 and 6)
        for y in [2, 3, 4, 6] { #expect(has(p, 14, y, .body)) }
        #expect(!has(Sprite.pixels(state: "working", frame: 0), 14, 2, .body))
    }

    @Test func attentionShowsQuestionMark() {
        let p = Sprite.pixels(state: "needs_attention", frame: 0)
        for (x, y) in [(6, 2), (7, 2), (8, 2), (8, 3), (7, 4), (7, 5), (7, 6)] { #expect(has(p, x, y, .body)) }
        #expect(has(Sprite.pixels(state: "needs_attention", frame: 1), 6, 2, .highlight))
    }

    @Test func doneSmilesAndSparkles() {
        let p = Sprite.pixels(state: "done", frame: 1)
        #expect(has(p, 7, 12, .dark) && has(p, 8, 12, .dark)) // smile
        #expect(has(p, 1, 3, .body))                           // sparkle on odd frames
        #expect(!has(Sprite.pixels(state: "done", frame: 0), 1, 3, .body))
    }

    @Test func sleepingSpritesHaveXEyesNoPupils() {
        for state in ["stale", "ended"] {
            let p = Sprite.pixels(state: state, frame: 0)
            #expect(!p.contains { $0.role == .pupil })
            #expect(has(p, 3, 9, .dark) && has(p, 4, 8, .dark)) // one diagonal of the left "x"
        }
        #expect(Sprite.pixels(state: "working", frame: 0).contains { $0.role == .pupil })
    }

    @Test func onlyWorkingMoves() {
        for state in ["stale", "ended"] {
            #expect(Sprite.pixels(state: state, frame: 0) == Sprite.pixels(state: state, frame: 1))
        }
    }
}

@Suite("Backoff — client reconnect")
struct BackoffTests {
    @Test func growsThenCaps() {
        #expect(Backoff.delay(attempt: 0) == 1)
        #expect(Backoff.delay(attempt: 1) == 2)
        #expect(Backoff.delay(attempt: 3) == 8)
        #expect(Backoff.delay(attempt: 5) == 30)
        #expect(Backoff.delay(attempt: 1000) == 30) // no overflow on long outages
    }
}
