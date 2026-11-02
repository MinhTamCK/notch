import Foundation

/// Fleet view rules shared with the web dashboard (server/public/index.html):
/// "the colour is the interface" — six state colours, most of the fleet grey.
/// Keyed by the server's raw state strings so the app and tests agree on them.
public enum Fleet {
    /// Display order within a machine: what needs Tam first, finished last.
    public static let order = ["needs_permission", "needs_attention", "working", "done", "stale", "ended"]

    public static func rank(_ state: String) -> Int {
        order.firstIndex(of: state) ?? order.count
    }

    /// State colour as 0xRRGGBB plus the card opacity (stale/ended are dimmed).
    public static func palette(_ state: String) -> (hex: UInt32, opacity: Double) {
        switch state {
        case "needs_permission": (0xF5A524, 1)
        case "needs_attention": (0xA78BFA, 1)
        case "done": (0x3ECF8E, 1)
        case "stale": (0x4A5060, 0.55)
        case "ended": (0x343843, 0.45)
        default: (0x8B93A1, 1) // working, and anything unknown stays grey
        }
    }

    /// needs_permission → needs_attention → working → done → stale → ended,
    /// then most recently updated first.
    public static func sorted<T>(_ items: [T], state: (T) -> String, updatedAt: (T) -> Double) -> [T] {
        items.sorted {
            let (a, b) = (rank(state($0)), rank(state($1)))
            return a != b ? a < b : updatedAt($0) > updatedAt($1)
        }
    }

    /// Sessions grouped by machine (alphabetical), each group in `sorted` order.
    public static func grouped<T>(
        _ items: [T], machine: (T) -> String, state: (T) -> String, updatedAt: (T) -> Double
    ) -> [(machine: String, items: [T])] {
        Dictionary(grouping: items, by: machine)
            .map { (machine: $0.key, items: sorted($0.value, state: state, updatedAt: updatedAt)) }
            .sorted { $0.machine < $1.machine }
    }

    /// "20s" / "5m" / "3h" / "2d", like the dashboard.
    public static func age(sinceMs: Double, nowMs: Double) -> String {
        let s = max(0, Int((nowMs - sinceMs) / 1000))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// The 16x18 crab-like mascot from the web dashboard, as pixels. Body fill is the
/// state colour; the expression and the signal above the head carry the rest.
public enum Sprite {
    public static let width = 16
    public static let height = 18

    public enum Role: Sendable, Equatable {
        case body       // state colour
        case dark       // eye sockets, x-eyes, smile (background colour)
        case pupil      // white
        case highlight  // the lighter violet flash on the "?"
    }

    public struct Pixel: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let role: Role
        public init(x: Int, y: Int, role: Role) { self.x = x; self.y = y; self.role = role }
    }

    private static let body = [
        "..############..",
        ".##############.",
        ".##ee######ee##.",
        ".##ee######ee##.",
        ".##############.",
        ".##############.",
        "..############..",
    ]

    /// Pixels in paint order (later ones overwrite earlier ones), for `frame`
    /// ticking every 0.5 s. A port of `sprite()` in server/public/index.html.
    public static func pixels(state: String, frame: Int) -> [Pixel] {
        var out: [Pixel] = []
        // The JS grid has the head signal at y = -3; shift everything down by 5.
        func px(_ x: Int, _ y: Int, _ role: Role) { out.append(Pixel(x: x, y: y + 5, role: role)) }

        let working = state == "working"
        let asleep = state == "ended" || state == "stale"
        let bob = working && frame % 2 == 1 ? -1 : 0

        for (y, row) in body.enumerated() {
            for (x, ch) in row.enumerated() {
                if ch == "#" { px(x, y + bob + 1, .body) }
                else if ch == "e" { px(x, y + bob + 1, asleep ? .body : .dark) }
            }
        }

        // Expression
        if asleep { // x-eyes
            for (x, y) in [(3, 2), (4, 3), (3, 3), (4, 2), (11, 2), (12, 3), (11, 3), (12, 2)] where (x + y) % 2 == 0 {
                px(x, y + bob + 1, .dark)
            }
        } else if state == "done" { // looking up + smile
            px(3, 3 + bob + 1, .pupil); px(12, 3 + bob + 1, .pupil)
            for (x, y) in [(6, 5), (9, 5), (7, 6), (8, 6)] { px(x, y + bob + 1, .dark) }
        } else { // working eyes shift every other beat
            let l = working ? (frame % 4 < 2 ? 0 : 1) : 0
            for (x, y) in [(3 + l, 2), (3 + l, 3), (11 + l, 2), (11 + l, 3)] { px(x, y + bob + 1, .pupil) }
        }

        // Legs: alternate while working
        for (i, x) in [2, 5, 9, 12].enumerated() {
            let off = working && (i + frame) % 2 == 1 ? 1 : 0
            px(x, 8 + bob + 1 + off, .body)
            px(x, 9 + bob + 1 + off, .body)
        }

        // Signals above the head
        switch state {
        case "needs_permission": // raised claw + "!"
            for (x, y) in [(14, -3), (14, -2), (14, -1), (14, 1)] { px(x, y, .body) }
            if frame % 2 == 1 { px(13, -3, .body); px(15, -3, .body) }
        case "needs_attention": // "?"
            for (x, y) in [(6, -3), (7, -3), (8, -3), (8, -2), (7, -1), (7, 0), (7, 1)] { px(x, y, .body) }
            if frame % 2 == 1 { px(6, -3, .highlight); px(8, -3, .highlight) }
        case "done" where frame % 2 == 1: // sparkles
            for (x, y) in [(1, -2), (14, -2), (2, -1), (13, -1)] { px(x, y, .body) }
        default:
            break
        }
        return out
    }
}

/// Client-mode reconnect delay: exponential from `base`, capped — so a dead
/// server or a rejected token isn't hammered every few seconds forever.
public enum Backoff {
    public static func delay(attempt: Int, base: Double = 1, cap: Double = 30) -> Double {
        guard attempt > 0 else { return base }
        return min(cap, base * pow(2, Double(min(attempt, 30))))
    }
}
