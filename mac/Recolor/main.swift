import AppKit

// Changes the colour of the SCREEN GLOW without touching the rest of the
// character.
//
// WHY NOT JUST REGENERATE
// -----------------------
// Asking the model for "the same character with a green screen" looks like the
// obvious path and was tried twice. Both times the framing changed, and the
// second time background removal failed against the new white background and
// returned wrong cutouts — a good set became a broken set.
//
// The screen is the SATURATED region of the image: the shell is pastel cream.
// So changing the colour is a deterministic operation on pixels that are
// already right, with zero framing risk. Faster, cheaper and exact.
//
// WHY SATURATION ALONE IS NOT ENOUGH
// ----------------------------------
// The first version painted everything saturated and warm, and along with the
// screen it took the shadow of the arms and the base: in the error state the
// character came out with a pink body. Calibrating the threshold does not
// help. Measured across the eight files, the screen lives between S=0.40 and
// S=0.49 and the shadow between S=0.37 and S=0.51 — the two ranges overlap,
// and no saturation cut separates one from the other.
//
// What separates them is GEOMETRY. The screen is a single large blob; the
// shadows are small loose blobs. Labelling the connected components, the
// largest is the screen in all eight states and at both resolutions, with a
// wide margin: the second largest blob does not reach 12% of its size.
//
// The remaining blobs go back to the body's amber. That is what makes the tool
// re-runnable: running it again over an already recoloured file re-targets the
// screen and also undoes the damage the previous version left in the shadows.
//
// Usage: recolor <input.png> <output.png> <hue 0-360>

func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h = 0.0
    if d > 0 {
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
}

func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let (r, g, b): (Double, Double, Double)
    switch h {
    case ..<60:   (r, g, b) = (c, x, 0)
    case ..<120:  (r, g, b) = (x, c, 0)
    case ..<180:  (r, g, b) = (0, c, x)
    case ..<240:  (r, g, b) = (0, x, c)
    case ..<300:  (r, g, b) = (x, 0, c)
    default:      (r, g, b) = (c, 0, x)
    }
    return (r + m, g + m, b + m)
}

let a = CommandLine.arguments
guard a.count == 4, let targetHue = Double(a[3]), targetHue >= 0, targetHue <= 360,
      let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: recolor <input.png> <output.png> <hue 0-360>"); exit(1)
}
let name = URL(fileURLWithPath: a[2]).lastPathComponent

let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// Separates what has colour — screen and warm shadow — from the shell's pastel
// cream. 0.34 was measured on these images.
let THRESHOLD = 0.34
// The amber of the body's shadow: median hue of the blobs outside the screen.
// It came to 35 degrees across all eight files and both resolutions, in a range
// of 33 to 37.
let AMBER = 35.0

var mask = [Bool](repeating: false, count: w * h)
var colour = [(Double, Double, Double)](repeating: (0, 0, 0), count: w * h)
for p in 0..<(w * h) {
    let i = p * 4
    let al = Double(px[i + 3]) / 255
    if al < 0.05 { continue }
    // Undo the premultiplication before measuring the colour, otherwise a
    // semi-transparent pixel looks darker than it is.
    let r = min(Double(px[i]) / 255 / al, 1)
    let g = min(Double(px[i + 1]) / 255 / al, 1)
    let b = min(Double(px[i + 2]) / 255 / al, 1)
    let measured = hsv(r, g, b)
    if measured.1 >= THRESHOLD { mask[p] = true; colour[p] = measured }
}

// Connected components over 4 neighbours, with an explicit stack: the screen
// has 20 thousand pixels and recursion at that depth blows the stack.
var label = [Int](repeating: 0, count: w * h)
var size = [0]
var next = 1
var stack: [Int] = []
for start in 0..<(w * h) where mask[start] && label[start] == 0 {
    label[start] = next
    stack.append(start)
    var n = 0
    while let q = stack.popLast() {
        n += 1
        let x = q % w, y = q / w
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
            let v = ny * w + nx
            if mask[v] && label[v] == 0 { label[v] = next; stack.append(v) }
        }
    }
    size.append(n)
    next += 1
}
guard let screen = (1..<next).max(by: { size[$0] < size[$1] }) else {
    print("  \(name): no saturated region — wrong file?"); exit(1)
}
let secondLargest = (1..<next).filter { $0 != screen }.map { size[$0] }.max() ?? 0

var painted = 0, preserved = 0
for p in 0..<(w * h) where mask[p] {
    let i = p * 4
    let al = Double(px[i + 3]) / 255
    let (_, sa, va) = colour[p]
    let hue: Double
    if label[p] == screen { hue = targetHue; painted += 1 } else { hue = AMBER; preserved += 1 }
    let (nr, ng, nb) = rgb(hue, sa, va)
    px[i]     = UInt8(max(0, min(255, nr * al * 255)))
    px[i + 1] = UInt8(max(0, min(255, ng * al * 255)))
    px[i + 2] = UInt8(max(0, min(255, nb * al * 255)))
}

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: a[2]))
// The second blob goes into the report on purpose: if it ever gets close to
// the screen, the "largest is the screen" assumption has broken and you can
// see it immediately.
print("  \(name): screen \(painted)px -> hue \(Int(targetHue)); shadow \(preserved)px in amber (2nd blob: \(secondLargest)px)")
