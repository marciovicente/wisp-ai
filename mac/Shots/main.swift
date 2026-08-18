import SwiftUI
import AppKit

// Renders the app's screens to PNGs for the documentation.
//
// WHY NOT JUST TAKE A SCREENSHOT
// ------------------------------
// A real screenshot of the panel carries real project names, real usage and
// the board's address on the local network — into a public README, permanently.
// Here the data is synthetic, so nothing personal ships with the docs.
//
// It also makes the awkward states easy: photographing `error` or `waiting`
// live means provoking a failure at the exact moment the shutter is open.
//
// And it is repeatable — the images can be regenerated when the interface
// changes, instead of drifting until they show a version nobody runs.
//
//   ./mac/shots.sh

let panelJSON = """
{
  "uptime_s": 7412, "events": 1284,
  "board_ip": "192.168.0.31", "board_age_s": 1,
  "board_bat": 62, "board_bat_chg": false, "tasks_done": 37,
  "sessions": [
    {"st":"tool",    "dt":"Bash",         "pj":"wisp-ai",   "md":"opus-5",  "age":2},
    {"st":"asking",  "dt":"Auth method",  "pj":"storefront","md":"opus-5",  "age":14},
    {"st":"working", "dt":"thinking",     "pj":"api",       "md":"sonnet-5","age":5}
  ],
  "limits": [
    {"l":"Session 5h",   "p":41, "r":"3h", "s":"normal",  "a":true},
    {"l":"Weekly",       "p":68, "r":"4d", "s":"warning", "a":false},
    {"l":"Weekly Opus",  "p":22, "r":"4d", "s":"normal",  "a":false}
  ],
  "limits_age_s": 48, "peak": 68,
  "usage": {"requests": 1841, "input": 92130, "output": 664200, "cache_read": 18400000},
  "open_network": false,
  "windows": {
    "ok": true,
    "session": {"output": 606311, "reqs": 638,   "peak": 967881,  "pct": 63},
    "week":    {"output": 4448942,"reqs": 12806, "peak": 6451634, "pct": 69},
    "history_d": 29.3
  }
}
"""

@MainActor
func write<V: View>(_ view: V, _ name: String, scale: CGFloat = 2, opaque: Bool = false) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    r.isOpaque = opaque
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("failed: \(name)"); exit(1)
    }
    let url = URL(fileURLWithPath: "docs/\(name).png")
    try! png.write(to: url)
    print("  docs/\(name).png  \(Int(img.size.width))x\(Int(img.size.height))")
}

MainActor.assumeIsolated {
    let bridge = Bridge.fixture(panelJSON)

    // The panel, on the material background the menu bar gives it — rendered
    // opaque, because a transparent PNG of a popover reads as a floating
    // rectangle on GitHub's white and its dark theme alike.
    write(Panel(bridge: bridge, showsFooter: false)
            .background(Color(nsColor: .windowBackgroundColor)),
          "panel", opaque: true)

    // The desktop mascot, transparent, the way it actually sits on a desktop.
    write(FloatingContent(bridge: bridge), "floating")

    // The eight states in a row: the single most communicative image, because
    // the whole project is one idea — a face that tells you where Claude is.
    write(HStack(alignment: .top, spacing: 18) {
        ForEach(MascotState.allCases, id: \.self) { s in
            VStack(spacing: 6) {
                Mascot(state: s, side: 62)
                Text(s.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }
    .padding(.horizontal, 22).padding(.vertical, 18)
    .background(Color(red: 0.09, green: 0.10, blue: 0.12)),
    "states", opaque: true)

    print("done")
}
