import AppKit
import Vision
import CoreImage

// Prepara um conjunto de mascotes para uso: tira o fundo e alinha os oito.
//
// POR QUE ISTO EXISTE
// -------------------
// Modelo de imagem não entrega PNG transparente, e não entrega os oito
// estados no mesmo enquadramento por mais que você peça. Medido no primeiro
// conjunto: `tool` e `waiting` saíram maiores e mais baixos que os outros.
// Trocando de estado, o boneco PULA — e pulo lê como falha, não como
// animação.
//
// Corrigir isso à mão, oito vezes, para cada personagem, é o tipo de trabalho
// que faz alguém desistir do projeto. Aqui é uma passada de comando.
//
// O que faz, em ordem:
//   1. separa o personagem do fundo (Vision, offline, sem serviço externo)
//   2. acha a caixa real do desenho pelo canal alfa
//   3. escala todos para a MESMA altura de personagem
//   4. assenta na mesma linha de base, centralizado
//
// O passo 3 é o que importa: normalizar pela altura do personagem, e não pelo
// tamanho do arquivo, é o que faz os oito virarem um só boneco.

let ESTADOS = ["idle", "working", "tool", "asking", "waiting", "done", "error", "offline"]
let LADO = 512
let MARGEM = 0.10      // folga em volta, para gestos que saem do corpo
let BASE = 0.04        // quanto sobra abaixo dos pés

func cgImagem(_ url: URL) -> CGImage? {
    guard let d = NSImage(contentsOf: url),
          let cg = d.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return cg
}

/// Separa o personagem do fundo. Offline, pela Vision do próprio macOS.
func semFundo(_ cg: CGImage) -> CGImage? {
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

/// Caixa do que realmente está desenhado, ignorando o transparente em volta.
func caixaVisivel(_ cg: CGImage) -> CGRect? {
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
        for x in 0..<w where px[(y * w + x) * 4 + 3] > 12 {   // 12: ignora franja
            if x < x0 { x0 = x }; if x > x1 { x1 = x }
            if y < y0 { y0 = y }; if y > y1 { y1 = y }
        }
    }
    guard x1 >= x0, y1 >= y0 else { return nil }
    return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

// ————————————————— execução

let pasta = URL(fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1]
                : FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".fagulha/mascotes/terminal").path)

var recortes: [(String, CGImage, CGRect)] = []
for n in ESTADOS {
    let url = pasta.appendingPathComponent("\(n).png")
    guard let cg = cgImagem(url) else { print("  \(n): não achei"); continue }
    let limpo = semFundo(cg) ?? cg
    guard let cx = caixaVisivel(limpo) else { print("  \(n): vazio"); continue }
    recortes.append((n, limpo, cx))
    print("  \(n): personagem \(Int(cx.width))x\(Int(cx.height)) em \(limpo.width)x\(limpo.height)")
}
guard !recortes.isEmpty else { exit(1) }

// A referência é o MAIOR personagem: encolher preserva detalhe, ampliar borra.
let alturaMax = recortes.map { $0.2.height }.max()!
let alvo = Double(LADO) * (1 - MARGEM * 2)
let escalaComum = alvo / Double(alturaMax)
print("\n  altura de referência: \(Int(alturaMax))px  ->  escala \(String(format: "%.3f", escalaComum))")

let saida = pasta.appendingPathComponent("normalizado", isDirectory: true)
try? FileManager.default.createDirectory(at: saida, withIntermediateDirectories: true)

for (n, cg, cx) in recortes {
    let lw = cx.width * escalaComum, lh = cx.height * escalaComum
    let destino = NSImage(size: NSSize(width: LADO, height: LADO))
    destino.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    // Recorta na caixa do personagem e assenta todos na mesma linha de base.
    if let corte = cg.cropping(to: cx) {
        NSImage(cgImage: corte, size: NSSize(width: cx.width, height: cx.height))
            .draw(in: NSRect(x: (Double(LADO) - lw) / 2,
                             y: Double(LADO) * BASE,
                             width: lw, height: lh))
    }
    destino.unlockFocus()
    if let t = destino.tiffRepresentation, let r = NSBitmapImageRep(data: t),
       let p = r.representation(using: .png, properties: [.compressionFactor: 0.9]) {
        try? p.write(to: saida.appendingPathComponent("\(n).png"))
    }
}
print("  normalizados em: \(saida.path)")
