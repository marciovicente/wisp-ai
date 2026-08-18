import SwiftUI
import AppKit

/// Loads image-based mascots from ~/.wisp/mascots/<name>/.
///
/// It exists so the character stops being hostage to what I can draw in code.
/// Procedural vectors scale well and weigh nothing, but they have a ceiling:
/// they do not reach the finish of a 3D render. With this, any art can come in
/// — hand-drawn, commissioned or generated — and the vector becomes the
/// factory default.
///
/// RULES
/// -----
/// One PNG per state, named the way the bridge names the states. If any one is
/// missing, the whole set is ignored and we fall back to the vector: a
/// coherent character beats seven pretty frames and a hole.
///
/// The images are static. The motion comes from the code — floating,
/// squashing, tilting. On a 46px character on the desktop, frame-by-frame
/// animation would be invisible work.
enum Sprites {

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".wisp/mascots", isDirectory: true)

    /// The state's name as a file name. These are the same names that travel
    /// through /state, so the project has no second translation table.
    static func file(_ s: MascotState) -> String {
        switch s {
        case .idle:     return "idle"
        case .working:  return "working"
        case .tool:     return "tool"
        case .asking:   return "asking"
        case .waiting:  return "waiting"
        case .done:     return "done"
        case .error:    return "error"
        case .offline:  return "offline"
        }
    }

    /// Which set to use. Empty = the built-in vector.
    static var chosen: String {
        get { UserDefaults.standard.string(forKey: "mascot") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "mascot")
            cache.removeAll()
            complete.removeAll()
        }
    }

    /// Available sets: subfolders that carry all eight states.
    static func available() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .filter { isComplete($0) }
            .sorted()
    }

    private static var cache: [String: NSImage] = [:]
    private static var complete: [String: Bool] = [:]

    /// A set only counts if it has EVERY state.
    static func isComplete(_ name: String) -> Bool {
        if let c = complete[name] { return c }
        let base = folder.appendingPathComponent(name, isDirectory: true)
        let ok = MascotState.allCases.allSatisfy { s in
            ["png", "PNG"].contains { ext in
                FileManager.default.fileExists(
                    atPath: base.appendingPathComponent("\(file(s)).\(ext)").path)
            }
        }
        complete[name] = ok
        return ok
    }

    static func image(_ s: MascotState) -> Image? {
        let name = chosen
        guard !name.isEmpty, isComplete(name) else { return nil }
        let key = "\(name)/\(file(s))"
        if let img = cache[key] { return Image(nsImage: img) }

        let base = folder.appendingPathComponent(name, isDirectory: true)
        for ext in ["png", "PNG"] {
            let url = base.appendingPathComponent("\(file(s)).\(ext)")
            if let img = NSImage(contentsOf: url) {
                cache[key] = img
                return Image(nsImage: img)
            }
        }
        return nil
    }
}

/// The image mascot, with its motion coming from the code.
///
/// The same gestures as the vector — breathing, squash and stretch, a curious
/// tilt — so both paths read as the same character in temperament, not just in
/// shape.
struct SpriteMascot: View {
    let state: MascotState
    let image: Image
    var side: CGFloat = 64

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = sin(t / state.period * 2 * .pi)

            // Squash & stretch: volume is conserved, so whatever stretches
            // vertically shrinks horizontally. Without it the character just
            // "inflates".
            let s = 1 + phase * state.breath
            // Floating follows the breathing, half a cycle behind — the body
            // rises after filling up, the way it really happens.
            let rise = CGFloat(sin(t / state.period * 2 * .pi - 0.9)) * side * 0.03
            // Curiosity and distress tilt the head; work does not.
            let tilt: Double = {
                switch state {
                case .asking:  return sin(t * 1.6) * 5
                case .waiting: return sin(t * 2.4) * 3
                case .error:   return -4
                default:       return 0
                }
            }()

            image
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .scaleEffect(x: 1 / s, y: s, anchor: .bottom)
                .rotationEffect(.degrees(tilt), anchor: .bottom)
                .offset(y: rise)
                .frame(width: side * 1.2, height: side * 1.2)
        }
        .accessibilityLabel("mascot: \(state.label)")
    }
}
