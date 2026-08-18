import SwiftUI
import AppKit

// Reproduces the desktop mascot walking down the screen, without touching the
// running app. Creates the same window with the same content, feeds it
// alternating data the way a real session does (the bubble grows and shrinks
// as the tool name and the project change), calls resize() the way the poll
// does, and prints the window's bottom edge each round.
//
// If the bottom edge moves, the drift is in the geometry, not in the animation.

func fixture(_ detail: String, _ project: String, _ n: Int) -> String {
    let sessions = (0..<n).map {
        "{\"st\":\"tool\",\"dt\":\"\(detail)\",\"pj\":\"\(project)\",\"md\":\"opus-5\",\"age\":\($0)}"
    }.joined(separator: ",")
    return """
    {"uptime_s":1,"events":1,"board_ip":"","board_age_s":-1,"board_bat":-1,
     "board_bat_chg":false,"tasks_done":0,"sessions":[\(sessions)],
     "limits":[],"limits_age_s":-1,"peak":-1,
     "usage":{"requests":1,"input":1,"output":1,"cache_read":1},
     "open_network":false,"windows":null}
    """
}

// Short bubble, long wrapping bubble, and no bubble at all.
let ROUNDS = [
    ("Bash", "api", 1),
    ("waiting for your permission to use AskUserQuestion", "some-long-project-name", 3),
    ("Read", "api", 1),
    ("", "", 0),
]

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    Sprites.folder = URL(fileURLWithPath: "firmware")
    Sprites.chosen = "assets"

    // Through the real path, so the anchoring in Floating.show() is what is
    // under test — not a copy of it.
    let bridge = Bridge.fixture(fixture("Bash", "api", 1))
    Floating.shared.show(bridge)
    guard let w = NSApp.windows.first(where: { $0 is FloatingWindow }) else {
        print("no floating window"); exit(1)
    }
    w.setFrameOrigin(NSPoint(x: 400, y: 400))

    func settle() {
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            w.contentView?.layoutSubtreeIfNeeded()
        }
    }
    settle()

    print("start   bottom=\(Int(w.frame.minY))  height=\(Int(w.frame.height))")

    for i in 0..<24 {
        let (d, p, n) = ROUNDS[i % ROUNDS.count]
        let before = w.frame
        bridge.load(fixture(d, p, n))
        settle()
        let moved = Int(w.frame.minY - before.minY)
        print(String(format: "round %2d  bottom=%5d  height=%4d  moved=%+d",
                     i, Int(w.frame.minY), Int(w.frame.height), moved))
    }
    print("end     bottom=\(Int(w.frame.minY))")
}
