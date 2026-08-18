import Foundation

/// Mirrors the bridge's GET /app payload.
///
/// The short names (`st`, `dt`, `pj`) come from /state, which was designed for
/// an ESP32 parsing JSON with little RAM. The app carries the same names rather
/// than translating halfway: one format, one place to get it wrong.

struct Session: Decodable, Identifiable {
    let st: String      // state: idle/working/tool/asking/waiting/done/error
    let dt: String      // detail: "Bash", "approve plan"…
    let pj: String      // project
    let md: String      // model
    let age: Int        // seconds since the last event

    var id: String { "\(pj)|\(st)|\(dt)|\(age)" }

    /// Dot colour. Same semantics as the mascot on the board.
    var colour: String {
        switch st {
        case "working", "tool": return "working"
        case "asking":          return "asking"
        case "waiting":         return "waiting"
        case "done":            return "done"
        case "error":           return "error"
        default:                return "idle"
        }
    }
}

struct Limit: Decodable, Identifiable {
    let l: String       // label
    let p: Int          // percentage
    let r: String       // when it resets
    let s: String       // severity
    let a: Bool         // this is the one that counts right now
    /// The window already rolled over, so `p` describes a period that no
    /// longer exists. Optional so an older bridge still decodes.
    let x: Bool?

    var id: String { l }
    var expired: Bool { x == true }
}

/// Usage in one window (5h or 7 days), computed from the local transcripts.
struct Band: Decodable {
    let output: Int
    let reqs: Int
    let peak: Int
    /// Percentage of YOUR peak in the period — never of Anthropic's limit,
    /// whose denominator is not public. -1 = history too short to compare.
    let pct: Int
    var comparable: Bool { pct >= 0 }
}

struct Windows: Decodable {
    let ok: Bool
    let session: Band?
    let week: Band?
    let history_d: Double?
}

struct Usage: Decodable {
    let requests: Int?
    let input: Int?
    let output: Int?
    let cache_read: Int?
}

struct AppState: Decodable {
    let uptime_s: Int
    let events: Int
    let board_ip: String
    let board_age_s: Int       // -1 = the board has never shown up
    /// The board's charge. Optional on purpose: an older bridge does not send
    /// these fields, and with a bare `Int` the whole decode would fail — the
    /// panel would go blank over an incidental number.
    let board_bat: Int?        // -1 = the board never reported a charge
    let board_bat_chg: Bool?
    /// How many tasks have finished since the bridge came up. Not for display:
    /// it is the trigger that tells the app when to ask for the limits.
    let tasks_done: Int?
    let sessions: [Session]
    let limits: [Limit]
    let limits_age_s: Int      // -1 = unavailable
    let peak: Int              // -1 = unavailable
    let usage: Usage
    /// true = the bridge answers anyone on the local network. It exists only
    /// for boards flashed before the token; it goes away once reflashed.
    let open_network: Bool?
    let windows: Windows?

    /// The state the large mascot shows: the most urgent among the sessions.
    ///
    /// The order is not aesthetic — it is about who depends on whom. "Asked
    /// you" and "needs you" come first because those are the two cases where
    /// Claude stopped and is waiting for YOU. Working can wait; blocked cannot.
    var dominantState: MascotState {
        for st in ["asking", "waiting", "error", "tool", "working", "done"]
        where sessions.contains(where: { $0.st == st }) {
            return MascotState(st)
        }
        return .idle
    }

    /// The board only counts as connected if it spoke to the bridge recently.
    /// It polls every 600ms; 10s of silence already means absence.
    var boardAlive: Bool { board_age_s >= 0 && board_age_s <= 10 }

    /// The board's charge, or nil when there is nothing to say: old bridge, a
    /// board that never reported, or a board with no cell installed. Nil
    /// disappears from the screen instead of becoming "--%", which would take
    /// up space to say nothing.
    var batteryPct: Int? {
        guard let b = board_bat, b >= 0 else { return nil }
        return b
    }
    var batteryCharging: Bool { board_bat_chg == true }
    /// Below this the charge stops being background information and becomes a
    /// warning. On the cable it does not warn: it is already fixing itself.
    var batteryLow: Bool { (batteryPct ?? 100) <= 20 && !batteryCharging }

    /// The limits cache should be at most 5 min old (Claude Code's own TTL).
    /// Past that the number on screen is fiction and has to appear with its
    /// age next to it.
    var limitsTrustworthy: Bool { limits_age_s >= 0 && limits_age_s < 300 }
}

/// Formats a big number without clutter: 251502 -> "251K", 3378109531 -> "3.4B".
func compact(_ n: Int?) -> String {
    guard let n = n else { return "—" }
    let d = Double(n)
    switch d {
    case 1e9...:  return String(format: "%.1fB", d / 1e9)
    case 1e6...:  return String(format: "%.1fM", d / 1e6)
    case 1e3...:  return String(format: "%.0fK", d / 1e3)
    default:      return "\(n)"
    }
}

/// "3d", "2h", "14min", "now" — the same short scale used on the board.
func shortAge(_ seconds: Int) -> String {
    switch seconds {
    case ..<60:      return "now"
    case ..<3600:    return "\(seconds / 60)min"
    case ..<86400:   return "\(seconds / 3600)h"
    default:         return "\(seconds / 86400)d"
    }
}
