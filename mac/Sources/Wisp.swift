import SwiftUI

/// Wisp — the Waveshare bridge, with a face.
///
/// The app exists for two practical reasons, in this order:
///
///   1. It IS the autostart. Before it, the bridge only ran while somebody had
///      it up in a terminal; a reboot left the board orphaned with no sign
///      that it had happened. Now there is an icon.
///   2. Usage becomes readable without depending on the board.
///
/// LSUIElement=true in Info.plist: no Dock icon, no window. Just the menu bar.
/// Shutdown: without this the bridge process outlives the app and is re-adopted
/// by PID 1 — measured, not assumed. It keeps serving forever, and its three
/// `dns-sd` children along with it, announcing a bridge you think you closed.
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated {
            Floating.shared.savePosition()
            Bridge.shared.stop()
        }
    }
}

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    @StateObject private var bridge = Bridge.shared

    var body: some Scene {
        MenuBarExtra {
            Panel(bridge: bridge)
        } label: {
            // Icon + the number that matters. It draws little attention while
            // everything is fine, and the percentage climbs with the pressure.
            HStack(spacing: 3) {
                Image(systemName: barIcon)
                Text(bridge.barLabel)
            }
            .onAppear { bridge.start() }
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon tells the state before you open the panel.
    private var barIcon: String {
        guard bridge.state.alive else { return "bolt.slash" }
        guard let d = bridge.data else { return "bolt" }
        if d.sessions.contains(where: { $0.st == "asking" || $0.st == "waiting" }) {
            return "bolt.badge.checkmark"   // the ball is in your court
        }
        if d.sessions.contains(where: { $0.st == "working" || $0.st == "tool" }) {
            return "bolt.fill"             // Claude working
        }
        return "bolt"
    }
}
