import SwiftUI
import AppKit

// Contact sheet for the mascot: draws the eight states into a PNG so you can
// look at them side by side. Run it with ../preview.sh
//
// It exists so you can work on the character without opening the app: change
// Sources/Mascot.swift, run this, look at the result. The whole loop takes
// about five seconds.

struct Sheet: View {
    let rows: [[MascotState]] = [
        [.idle, .working, .tool, .asking],
        [.waiting, .done, .error, .offline],
    ]
    var body: some View {
        VStack(spacing: 14) {
            // Large, to judge the drawing…
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 16) {
                    ForEach(rows[i], id: \.self) { s in
                        VStack(spacing: 4) {
                            Mascot(state: s, side: 76)
                            Text(s.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
            // …and small, which is how it shows up in the session list. A
            // character that only works large is no good: here it lives at
            // 20px most of the time.
            HStack(spacing: 10) {
                ForEach(MascotState.allCases, id: \.self) { s in
                    Mascot(state: s, side: 22)
                }
            }
            .padding(.top, 2)
        }
        .padding(20)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }
}

@MainActor
func render(_ destination: String) {
    let r = ImageRenderer(content: Sheet())
    r.scale = 2
    guard let img = r.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("rendering failed")
        exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: destination))
    print(destination)
}

MainActor.assumeIsolated { render(CommandLine.arguments[1]) }
