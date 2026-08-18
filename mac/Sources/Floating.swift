import SwiftUI
import AppKit

/// The mascot loose on the desktop.
///
/// ONE mascot, large, with no frame.
///
/// The first version showed one character per session, copying what the board
/// does. On a desktop that does not work: four 46px characters on a screen
/// full of windows turn into confetti, and none of them is big enough for you
/// to read the expression at a glance — which is the only thing the mascot has
/// to do.
///
/// Here the split is different. One large character carries the STATE, a
/// bubble says WHAT is happening, and a counter tells you there is more than
/// one session. The board keeps splitting into several because there the space
/// is dedicated: the whole screen belongs to the mascot, and nothing competes
/// with it for attention.
///
/// No backing plate: with the PNG already cut out, any rectangle behind it
/// becomes a box floating on your desktop. The character has to look like it
/// is resting there.

struct FloatingContent: View {
    @ObservedObject var bridge: Bridge

    /// Large on purpose. It used to be 46px, a size at which the character's
    /// face cannot be read — and a face you cannot read makes the mascot
    /// decoration.
    private let size: CGFloat = 104

    private var sessions: [Session] { bridge.data?.sessions ?? [] }

    private var state: MascotState {
        guard bridge.state.alive else { return .offline }
        return bridge.data?.dominantState ?? .idle
    }

    /// What shows up in the bubble: the most urgent session is the one talking.
    private var speech: (String, String)? {
        guard let d = bridge.data, !d.sessions.isEmpty else { return nil }
        let dom = d.dominantState
        let s = d.sessions.first { MascotState($0.st) == dom } ?? d.sessions[0]
        let what = s.dt.isEmpty ? dom.label : s.dt
        return (what, s.pj)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let (what, project) = speech {
                bubble(what, project)
                    .padding(.bottom, 2)
            }
            Mascot(state: state, side: size)
        }
        .padding(8)
        // No background. See the comment at the top.
    }

    /// A speech bubble with a little tail pointing at the mascot.
    private func bubble(_ what: String, _ project: String) -> some View {
        VStack(spacing: 1) {
            Text(what)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                // Two lines, centred. A single line does not "trim the
                // excess": with the fixedSize below it laid the bubble out at
                // the full width of the sentence and the 190pt frame clipped
                // BOTH sides, leaving the middle of a sentence with no
                // beginning and no end.
                .lineLimit(2)
                .multilineTextAlignment(.center)
            // Project and count on the SAME line.
            //
            // The counter used to be an orange circle floating next to the
            // mascot, and it competed with the bubble instead of completing
            // it: two elements fighting over "what is happening". Here it
            // becomes what it always was — a detail of the project that is
            // talking.
            //
            // "+1" means one OTHER session besides this one, not the total:
            // whoever is talking is already named right next to it.
            if !project.isEmpty || sessions.count > 1 {
                HStack(spacing: 4) {
                    if !project.isEmpty {
                        Text(project)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if sessions.count > 1 {
                        Text("+\(sessions.count - 1)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.state("working"))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            // The tail: a small triangle, offset past the edge.
            Triangle()
                .fill(.regularMaterial)
                .frame(width: 12, height: 7)
                .offset(y: 6)
        }
        // Horizontal NO: the frame below is what governs the width, otherwise
        // the text ignores the limit and overflows. Vertical YES: that is what
        // lets the bubble grow to a second line instead of squeezing.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 190)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - window

final class FloatingWindow: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                   // .nonactivatingPanel: clicking the mascot does not steal
                   // focus from whatever you are doing.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        // Without this the panel disappears when the app loses focus — and the
        // app lives without focus, because it is LSUIElement.
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Floating {
    static let shared = Floating()
    private var window: FloatingWindow?
    private static let positionKey = "floatingPosition"

    func show(_ bridge: Bridge) {
        if window != nil { return }
        let w = FloatingWindow()
        let host = NSHostingView(rootView: FloatingContent(bridge: bridge))
        w.contentView = host
        w.setContentSize(host.fittingSize)

        if let s = UserDefaults.standard.string(forKey: Self.positionKey) {
            w.setFrameOrigin(NSPointFromString(s))
        } else if let screen = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: screen.maxX - host.fittingSize.width - 28,
                                     y: screen.minY + 28))
        }
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        savePosition()
        window?.orderOut(nil)
        window = nil
    }

    func savePosition() {
        guard let w = window else { return }
        UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: Self.positionKey)
    }

    /// The bubble changes width with the text, and the frame does not follow on
    /// its own. We keep the BOTTOM LEFT corner fixed: that way the mascot stays
    /// put and it is the bubble that grows upward, instead of the character
    /// sliding across the desktop on every tool change.
    func resize() {
        guard let w = window, let host = w.contentView else { return }
        let size = host.fittingSize
        guard abs(w.frame.width - size.width) > 1 || abs(w.frame.height - size.height) > 1
        else { return }
        let origin = NSPoint(x: w.frame.minX, y: w.frame.minY)
        w.setContentSize(size)
        w.setFrameOrigin(origin)
    }
}
