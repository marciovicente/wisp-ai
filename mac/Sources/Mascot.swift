import SwiftUI

/// Wisp's mascot — a living light.
///
/// ABOUT THE DRAWING
/// -----------------
/// The first version was a rounded square with two vertical slits. It read as
/// a pig's snout, and rightly so: it only had eyes. Expression in a character
/// comes from the EYEBROWS and the MOUTH — without them, eight states become
/// the same character painted in different colours.
///
/// This version has five layers of expression, in order of how much each one
/// carries:
///
///   1. eyebrows  angle and height. They do almost all the work: the same face
///                with the inner brow raised becomes worry, and with the outer
///                brow raised becomes surprise.
///   2. mouth     curvature and width.
///   3. gaze      where the pupil points. Looking up and to the side is the
///                universal gesture for "I am thinking".
///   4. opening   the eyelid. Narrowed eyes read as concentration.
///   5. body      a flame silhouette that leans and stretches.
///
/// The silhouette is no longer a square: it is a flame droplet, wider at the
/// bottom, tapering into a rounded top, with a tongue of fire flickering above
/// the head. That ties the character to the name.
///
/// It is all vectors drawn in code — no image files. It scales from 20px (in
/// the session list) to 200px losing nothing, and the same code describes the
/// character on the board.

enum MascotState: String, CaseIterable {
    case idle, working, tool, asking
    case waiting, done, error, offline

    init(_ st: String) {
        switch st {
        case "working":  self = .working
        case "tool":     self = .tool
        case "asking":   self = .asking
        case "waiting":  self = .waiting
        case "done":     self = .done
        case "error":    self = .error
        case "offline":  self = .offline
        default:         self = .idle
        }
    }

    /// (top, bottom) of the body gradient.
    var colors: (Color, Color) {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255)
        }
        switch self {
        case .idle:     return (c(242, 156, 92),  c(206, 92, 58))
        case .working:  return (c(250, 168, 84),  c(216, 96, 50))
        case .tool:     return (c(250, 186, 78),  c(214, 118, 44))
        case .asking:   return (c(198, 152, 246), c(132, 92, 190))
        case .waiting:  return (c(246, 206, 96),  c(206, 152, 48))
        case .done:     return (c(112, 220, 154), c(56, 152, 102))
        case .error:    return (c(238, 122, 108), c(184, 66, 62))
        case .offline:  return (c(126, 134, 148), c(74, 80, 92))
        }
    }

    var label: String {
        switch self {
        case .idle:     return "idle"
        case .working:  return "thinking"
        case .tool:     return "working"
        case .asking:   return "asked you"
        case .waiting:  return "needs you"
        case .done:     return "finished"
        case .error:    return "failed"
        case .offline:  return "no connection"
        }
    }

    var hasWisp: Bool { self == .working || self == .tool }
    var hasQuestionMarks: Bool { self == .asking }
    /// The flame on top dies when there is no life on the other side.
    var hasFlame: Bool { self != .offline }

    var breath: Double {
        switch self {
        case .idle: return 0.055
        case .working, .tool: return 0.030
        case .asking, .waiting: return 0.045
        case .done: return 0.070
        default: return 0.020
        }
    }

    var period: Double {
        switch self {
        case .idle: return 3.0
        case .working, .tool: return 1.6
        case .waiting, .asking: return 1.15
        case .done: return 0.9
        default: return 3.6
        }
    }

    var expression: Expression {
        switch self {
        case .idle:
            return Expression(brow: 0, browHeight: 0,
                              mouth: .smile, opening: 0.92, gaze: .zero)
        case .working:
            // Looking up and to the side: the gesture of someone thinking.
            return Expression(brow: -6, browHeight: 0.04,
                              mouth: .small, opening: 0.85,
                              gaze: CGPoint(x: 0.45, y: -0.5))
        case .tool:
            // Focused: narrowed eyes, low brow, tip of the tongue out.
            return Expression(brow: -16, browHeight: -0.05,
                              mouth: .tongue, opening: 0.62, gaze: CGPoint(x: 0, y: 0.15))
        case .asking:
            // Outer brow raised = surprise/question. Mouth in an "o".
            return Expression(brow: 14, browHeight: 0.10,
                              mouth: .o, opening: 1.05, gaze: CGPoint(x: 0, y: -0.1))
        case .waiting:
            return Expression(brow: 20, browHeight: 0.08,
                              mouth: .wavy, opening: 1.0, gaze: CGPoint(x: 0, y: 0.1))
        case .done:
            // Eyes closed in an upward arc — the smile that lives in the eyes.
            return Expression(brow: 8, browHeight: 0.06,
                              mouth: .bigSmile, opening: 0, gaze: .zero,
                              happyEyes: true)
        case .error:
            // INNER brow raised: worry, not anger.
            return Expression(brow: -22, browHeight: 0.02,
                              mouth: .wavy, opening: 0.75, gaze: CGPoint(x: 0, y: 0.25),
                              inverted: true)
        case .offline:
            return Expression(brow: 0, browHeight: -0.03,
                              mouth: .flat, opening: 0.12, gaze: .zero)
        }
    }
}

struct Expression {
    /// Degrees. Positive raises the OUTER tip (surprise); negative lowers it
    /// (concentration). With `inverted`, the inner tip is the one that rises,
    /// which is the difference between looking angry and looking worried.
    var brow: Double
    var browHeight: Double
    var mouth: Mouth
    /// 1 = a normal eye. 0 = closed.
    var opening: Double
    /// Pupil direction, -1 to 1 on each axis.
    var gaze: CGPoint
    var happyEyes: Bool = false
    var inverted: Bool = false
}

enum Mouth { case smile, bigSmile, small, o, flat, wavy, tongue }

/// How much larger the frame is than the body, so the flame, the orbiting
/// light and the question marks fit without being clipped.
private let MARGIN: CGFloat = 1.42

struct Mascot: View {
    let state: MascotState
    var side: CGFloat = 64

    @ViewBuilder
    var body: some View {
        // The user's art takes precedence. The vector is the factory default,
        // not the main path — and it remains the safety net when a state is
        // missing.
        if let img = Sprites.image(state) {
            SpriteMascot(state: state, image: img, side: side * MARGIN)
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Canvas { g, size in draw(&g, size, t) }
                    .frame(width: side * MARGIN, height: side * MARGIN)
            }
            .accessibilityLabel("mascot: \(state.label)")
        }
    }

    // MARK: - silhouette

    /// A flame droplet: a wide, rounded base tapering into a soft top. Neither
    /// a circle nor a square — the silhouette is the first thing you recognise
    /// in a character, before any detail.
    private func bodyPath(_ r: CGRect, stretch: Double) -> Path {
        let w = r.width
        let h = r.height * (1 + stretch)
        let cx = r.midX
        let top = r.maxY - h
        var p = Path()
        p.move(to: CGPoint(x: cx, y: top))
        // left side, coming down
        p.addCurve(to: CGPoint(x: cx - w * 0.50, y: top + h * 0.60),
                   control1: CGPoint(x: cx - w * 0.30, y: top + h * 0.02),
                   control2: CGPoint(x: cx - w * 0.50, y: top + h * 0.28))
        // left base, rounding off
        p.addCurve(to: CGPoint(x: cx, y: r.maxY),
                   control1: CGPoint(x: cx - w * 0.50, y: r.maxY - h * 0.02),
                   control2: CGPoint(x: cx - w * 0.26, y: r.maxY))
        // right base
        p.addCurve(to: CGPoint(x: cx + w * 0.50, y: top + h * 0.60),
                   control1: CGPoint(x: cx + w * 0.26, y: r.maxY),
                   control2: CGPoint(x: cx + w * 0.50, y: r.maxY - h * 0.02))
        // right side, going up
        p.addCurve(to: CGPoint(x: cx, y: top),
                   control1: CGPoint(x: cx + w * 0.50, y: top + h * 0.28),
                   control2: CGPoint(x: cx + w * 0.30, y: top + h * 0.02))
        p.closeSubpath()
        return p
    }

    /// The light floating above the head — the will-o'-the-wisp the project is
    /// named after.
    ///
    /// In the first version it was born glued to the top and used the body's
    /// colour. The result was a little brown stalk: the character turned into a
    /// pumpkin. Two things fix that, and both are about how fire works.
    ///
    /// First, fire is BRIGHTER than what it lights — an almost white core, not
    /// the same paint as the body. Second, a flame has a belly: it widens a
    /// little before tapering at the tip, and the tip leans to one side. A
    /// symmetrical cone reads as a plant stem.
    ///
    /// It also floats with a gap above the head instead of sprouting from it —
    /// that way it is a companion, not a stalk.
    private func flamePath(_ cx: CGFloat, _ base: CGFloat, _ d: CGFloat,
                           _ f: Double) -> Path {
        let h = d * (0.21 + 0.045 * f)
        let w = d * (0.115 + 0.012 * f)
        let lean = CGFloat(f) * d * 0.045      // the tip sways
        var p = Path()
        p.move(to: CGPoint(x: cx, y: base))
        // up the left, with a belly
        p.addCurve(to: CGPoint(x: cx + lean, y: base - h),
                   control1: CGPoint(x: cx - w * 1.15, y: base - h * 0.18),
                   control2: CGPoint(x: cx - w * 0.72, y: base - h * 0.74))
        // down the right
        p.addCurve(to: CGPoint(x: cx, y: base),
                   control1: CGPoint(x: cx + w * 0.78, y: base - h * 0.72),
                   control2: CGPoint(x: cx + w * 1.15, y: base - h * 0.16))
        p.closeSubpath()
        return p
    }

    // MARK: - drawing

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ t: TimeInterval) {
        let d = side
        let e = state.expression
        let (top, bottom) = state.colors

        let body = CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2 + d * 0.06,
                          width: d, height: d * 0.94)

        // breathing: stretches and shrinks the whole body (squash & stretch)
        let phase = sin(t / state.period * 2 * .pi)
        let stretch = phase * state.breath

        // blink
        let cycle = 4.2 + Double(abs(state.hashValue) % 5) * 0.6
        let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle
        let blinking = p > 0.972 && e.opening > 0.2
        let opening = blinking ? 0.06 : e.opening * (1 + phase * 0.05)

        // —— the flame on top
        if state.hasFlame {
            let flick = sin(t * 7.3) * 0.5 + sin(t * 4.1) * 0.5
            let bodyTop = body.maxY - body.height * (1 + stretch)
            let flameBase = bodyTop - d * 0.05        // it floats, it does not sprout
            let fl = flamePath(body.midX, flameBase, d, flick)
            // halo: what makes the drawing read as light instead of a cutout
            g.fill(fl.applying(CGAffineTransform(translationX: 0, y: 0)),
                   with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.35).opacity(0.30),
                                      .clear]),
                    center: CGPoint(x: body.midX, y: flameBase - d * 0.10),
                    startRadius: 0, endRadius: d * 0.26))
            g.fill(fl, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.98, blue: 0.86),
                                  Color(red: 1.0, green: 0.82, blue: 0.32),
                                  Color(red: 0.99, green: 0.55, blue: 0.18)]),
                startPoint: CGPoint(x: body.midX, y: flameBase - d * 0.24),
                endPoint: CGPoint(x: body.midX, y: flameBase)))
        }

        // —— body
        let silhouette = bodyPath(body, stretch: stretch)
        g.fill(silhouette, with: .linearGradient(
            Gradient(colors: [top, bottom]),
            startPoint: CGPoint(x: body.midX, y: body.minY),
            endPoint: CGPoint(x: body.midX, y: body.maxY)))
        // light from above, so the body does not read as a flat cutout
        g.fill(silhouette, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.22), .clear]),
            center: CGPoint(x: body.midX - d * 0.14, y: body.minY + d * 0.16),
            startRadius: 0, endRadius: d * 0.55))

        // face geometry
        let realHeight = body.height * (1 + stretch)
        let eyeY = body.maxY - realHeight * 0.52
        let sep = d * 0.185
        let rEye = d * 0.125

        // —— eyes
        for (i, dx) in [-sep, sep].enumerated() {
            let cx = body.midX + dx
            if e.happyEyes {
                // an upward arc: the smile that lives in the eyes
                var arc = Path()
                arc.addArc(center: CGPoint(x: cx, y: eyeY + rEye * 0.35),
                           radius: rEye * 0.95,
                           startAngle: .degrees(200), endAngle: .degrees(340),
                           clockwise: false)
                g.stroke(arc, with: .color(.black.opacity(0.72)),
                         style: StrokeStyle(lineWidth: d * 0.045, lineCap: .round))
                continue
            }

            let h = rEye * 2 * opening
            let white = CGRect(x: cx - rEye, y: eyeY - h / 2,
                               width: rEye * 2, height: max(d * 0.02, h))
            g.fill(Path(ellipseIn: white), with: .color(.white.opacity(0.97)))

            if opening > 0.25 {
                // pupil: follows the gaze, kept inside the white
                let px = cx + e.gaze.x * rEye * 0.40
                let py = eyeY + e.gaze.y * rEye * 0.34 * opening
                let rp = rEye * 0.52
                g.fill(Path(ellipseIn: CGRect(x: px - rp, y: py - rp,
                                              width: rp * 2, height: rp * 2)),
                       with: .color(Color(red: 0.10, green: 0.07, blue: 0.09)))
                // highlight: the dot that separates "a live eye" from "a black hole"
                let rb = rEye * 0.20
                g.fill(Path(ellipseIn: CGRect(x: px - rp * 0.45 - rb / 2,
                                              y: py - rp * 0.45 - rb / 2,
                                              width: rb * 2, height: rb * 2)),
                       with: .color(.white.opacity(0.92)))
            }
            _ = i
        }

        // —— eyebrows: where most of the expression lives
        if state.hasFlame {
            for dx in [-sep, sep] {
                let outer = dx < 0 ? -1.0 : 1.0
                let turn = (e.inverted ? -outer : outer) * e.brow
                let cx = body.midX + dx
                let cy = eyeY - rEye * 1.55 - CGFloat(e.browHeight) * d
                let w = rEye * 1.7
                var s = Path()
                s.move(to: CGPoint(x: -w / 2, y: 0))
                s.addQuadCurve(to: CGPoint(x: w / 2, y: 0),
                               control: CGPoint(x: 0, y: -w * 0.22))
                let tr = CGAffineTransform(translationX: cx, y: cy)
                    .rotated(by: .pi / 180 * turn)
                g.stroke(s.applying(tr), with: .color(.black.opacity(0.55)),
                         style: StrokeStyle(lineWidth: d * 0.042, lineCap: .round))
            }
        }

        // —— mouth
        drawMouth(&g, e.mouth, body, eyeY + rEye * 2.1, d, t)

        // —— cheeks
        if state.hasFlame {
            for dx in [-sep * 1.75, sep * 1.75] {
                let rb = d * 0.075
                g.fill(Path(ellipseIn: CGRect(x: body.midX + dx - rb,
                                              y: eyeY + rEye * 1.1 - rb * 0.6,
                                              width: rb * 2, height: rb * 1.2)),
                       with: .color(.white.opacity(0.16)))
            }
        }

        // —— the orbiting light
        if state.hasWisp {
            let ang = t * 2.0
            let radius = d * 0.62
            let fx = body.midX + cos(ang) * radius
            let fy = body.midY + sin(ang) * radius * 0.46
            let s = d * 0.10
            g.fill(Path(ellipseIn: CGRect(x: fx - s / 2, y: fy - s / 2,
                                          width: s, height: s)),
                   with: .color(top))
            g.fill(Path(ellipseIn: CGRect(x: fx - s * 0.9, y: fy - s * 0.9,
                                          width: s * 1.8, height: s * 1.8)),
                   with: .color(top.opacity(0.20)))
        }

        // —— question marks
        if state.hasQuestionMarks {
            for i in 0..<3 {
                let f = ((t + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.7)) / 1.7
                let y = body.minY - d * 0.04 - CGFloat(f) * d * 0.16
                let alpha = f < 0.25 ? f / 0.25 : (1 - f) / 0.75
                g.opacity = alpha
                g.draw(Text("?").font(.system(size: d * 0.26, weight: .heavy))
                        .foregroundStyle(top),
                       at: CGPoint(x: body.midX + (Double(i) - 1) * d * 0.26, y: y))
                g.opacity = 1
            }
        }
    }

    private func drawMouth(_ g: inout GraphicsContext, _ m: Mouth,
                           _ body: CGRect, _ y: CGFloat, _ d: CGFloat,
                           _ t: TimeInterval) {
        let cx = body.midX
        let dark = Color.black.opacity(0.62)
        let stroke = StrokeStyle(lineWidth: d * 0.045, lineCap: .round)

        switch m {
        case .smile, .bigSmile:
            let w = d * (m == .bigSmile ? 0.30 : 0.20)
            let depth = d * (m == .bigSmile ? 0.14 : 0.075)
            var p = Path()
            p.move(to: CGPoint(x: cx - w / 2, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + w / 2, y: y),
                           control: CGPoint(x: cx, y: y + depth * 2))
            if m == .bigSmile {
                p.closeSubpath()
                g.fill(p, with: .color(dark))
            } else {
                g.stroke(p, with: .color(dark), style: stroke)
            }

        case .small:
            var p = Path()
            p.move(to: CGPoint(x: cx - d * 0.055, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + d * 0.055, y: y),
                           control: CGPoint(x: cx, y: y + d * 0.05))
            g.stroke(p, with: .color(dark), style: stroke)

        case .o:
            let r = d * 0.062
            g.fill(Path(ellipseIn: CGRect(x: cx - r, y: y - r * 0.8,
                                          width: r * 2, height: r * 2.1)),
                   with: .color(dark))

        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: cx - d * 0.08, y: y))
            p.addLine(to: CGPoint(x: cx + d * 0.08, y: y))
            g.stroke(p, with: .color(dark), style: stroke)

        case .wavy:
            // A zigzag mouth: the universal drawing for discomfort.
            var p = Path()
            let w = d * 0.20, steps = 4
            p.move(to: CGPoint(x: cx - w / 2, y: y))
            for i in 1...steps {
                let x = cx - w / 2 + w * CGFloat(i) / CGFloat(steps)
                let dy = (i % 2 == 0 ? 1.0 : -1.0) * d * 0.028
                p.addQuadCurve(to: CGPoint(x: x, y: y),
                               control: CGPoint(x: x - w / CGFloat(steps) / 2,
                                                y: y + dy))
            }
            g.stroke(p, with: .color(dark), style: stroke)

        case .tongue:
            var p = Path()
            p.move(to: CGPoint(x: cx - d * 0.09, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + d * 0.09, y: y),
                           control: CGPoint(x: cx, y: y + d * 0.06))
            g.stroke(p, with: .color(dark), style: stroke)
            // the tip of the tongue, in the corner — a sign of concentration
            let lr = d * 0.045
            let sway = CGFloat(sin(t * 3)) * d * 0.008
            g.fill(Path(ellipseIn: CGRect(x: cx + d * 0.035 + sway, y: y + d * 0.012,
                                          width: lr * 1.6, height: lr * 1.8)),
                   with: .color(Color(red: 0.95, green: 0.45, blue: 0.48)))
        }
    }
}
