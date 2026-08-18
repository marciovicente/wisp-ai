import AppKit
import Vision
import CoreImage

// Prepares a mascot set for use: removes the background and aligns all eight.
//
// WHY THIS EXISTS
// ---------------
// An image model does not hand you a transparent PNG, and it does not hand you
// the eight states at the same framing however hard you ask. Measured on the
// first set: `tool` and `waiting` came out larger and lower than the others.
// On a state change the character JUMPS — and a jump reads as a bug, not as
// animation.
//
// Fixing that by hand, eight times, for every character, is the kind of work
// that makes someone abandon the project. Here it is one command.
//
// What it does, in order:
//   1. separates the character from the background (Vision, offline, no
//      external service)
//   2. finds the drawing's real box from the alpha channel
//   3. scales them all to the SAME character height
//   4. seats them on the same baseline, centred
//
// Step 3 is the one that matters: normalising by the character's height, not
// by the file size, is what turns eight images into one character.

let STATES = ["idle", "working", "tool", "asking", "waiting", "done", "error", "offline"]
let SIDE = 512
let MARGIN = 0.10      // room around it, for gestures that leave the body
let BASE = 0.04        // how much is left below the feet

func cgImage(_ url: URL) -> CGImage? {
    guard let d = NSImage(contentsOf: url),
          let cg = d.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return cg
}

/// Separates the character from the background. Offline, through macOS's own
/// Vision framework.
func withoutBackground(_ cg: CGImage) -> CGImage? {
    let req = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cg)
    guard (try? handler.perform([req])) != nil,
          let r = req.results?.first else { return nil }
    guard let buf = try? r.generateMaskedImage(ofInstances: r.allInstances,
                                               from: handler,
                                               croppedToInstancesExtent: false)
    else { return nil }
    let ci = CIImage(cvPixelBuffer: buf)
    return CIContext().createCGImage(ci, from: ci.extent)
}

/// The box of what is actually drawn, ignoring the transparency around it.
func visibleBox(_ cg: CGImage) -> CGRect? {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w where px[(y * w + x) * 4 + 3] > 12 {   // 12: ignore the fringe
            if x < x0 { x0 = x }; if x > x1 { x1 = x }
            if y < y0 { y0 = y }; if y > y1 { y1 = y }
        }
    }
    guard x1 >= x0, y1 >= y0 else { return nil }
    return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

// ————————————————— run

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : FileManager.default.homeDirectoryForCurrentUser
                     .appendingPathComponent(".wisp/mascots/terminal").path)

var crops: [(String, CGImage, CGRect)] = []
for n in STATES {
    let url = folder.appendingPathComponent("\(n).png")
    guard let cg = cgImage(url) else { print("  \(n): not found"); continue }
    let clean = withoutBackground(cg) ?? cg
    guard let box = visibleBox(clean) else { print("  \(n): empty"); continue }
    crops.append((n, clean, box))
    print("  \(n): character \(Int(box.width))x\(Int(box.height)) in \(clean.width)x\(clean.height)")
}
guard !crops.isEmpty else { exit(1) }

// The reference is the MEDIAN, not the maximum.
//
// With the maximum, a single out-of-spec file dragged the whole set along: one
// generation coming back zoomed in was enough to shrink the other seven into
// thumbnails. Measured, and that is how a good set became a bad one. The
// median ignores the outlier instead of obeying it.
let sorted = crops.map { $0.2.height }.sorted()
let referenceHeight = sorted[sorted.count / 2]
let target = Double(SIDE) * (1 - MARGIN * 2)
let commonScale = target / Double(referenceHeight)
print("\n  reference height: \(Int(referenceHeight))px  ->  scale \(String(format: "%.3f", commonScale))")

let out = folder.appendingPathComponent("normalized", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (n, cg, box) in crops {
    let w = box.width * commonScale, h = box.height * commonScale
    let canvas = NSImage(size: NSSize(width: SIDE, height: SIDE))
    canvas.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    // Crop to the character's box and seat them all on the same baseline.
    if let cut = cg.cropping(to: box) {
        NSImage(cgImage: cut, size: NSSize(width: box.width, height: box.height))
            .draw(in: NSRect(x: (Double(SIDE) - w) / 2,
                             y: Double(SIDE) * BASE,
                             width: w, height: h))
    }
    canvas.unlockFocus()
    if let t = canvas.tiffRepresentation, let r = NSBitmapImageRep(data: t),
       let p = r.representation(using: .png, properties: [.compressionFactor: 0.9]) {
        try? p.write(to: out.appendingPathComponent("\(n).png"))
    }
}
print("  normalized into: \(out.path)")
