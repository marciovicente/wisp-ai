import AppKit

// Troca a cor do BRILHO DA TELA sem tocar no resto do personagem.
//
// POR QUE NAO GERAR DE NOVO
// -------------------------
// Pedir ao modelo "o mesmo boneco com a tela verde" parece o caminho obvio e
// foi tentado duas vezes. Nas duas o enquadramento mudou, e na segunda a
// remocao de fundo falhou sobre o fundo branco novo e devolveu recortes
// errados — um conjunto bom virou um conjunto quebrado.
//
// A tela e a unica regiao SATURADA da imagem: a carcaca e creme pastel, os
// pixels do rosto sao marrom escuro. Entao trocar a cor e uma operacao
// deterministica sobre os pixels que ja estao certos, com zero risco de
// enquadramento. Mais rapido, mais barato e exato.
//
// Uso: recolorir <entrada.png> <saida.png> <matiz 0-360>

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
guard a.count == 4, let alvo = Double(a[3]),
      let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("uso: recolorir <entrada.png> <saida.png> <matiz 0-360>"); exit(1)
}

let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// Limiar de saturacao: separa a tela (vivida) da carcaca creme (pastel).
// 0.34 foi medido nestas imagens — abaixo disso o creme comeca a virar junto.
let LIMIAR = 0.34
var tocados = 0

for i in stride(from: 0, to: px.count, by: 4) {
    let al = Double(px[i + 3]) / 255
    if al < 0.05 { continue }
    // Desfaz a pre-multiplicacao antes de medir a cor, senao pixel
    // semitransparente parece mais escuro do que e.
    let r = Double(px[i]) / 255 / al
    let g = Double(px[i + 1]) / 255 / al
    let b = Double(px[i + 2]) / 255 / al
    let (hu, sa, va) = hsv(min(r, 1), min(g, 1), min(b, 1))
    // Ambar vive entre 15 e 60 graus. Restringir a faixa evita mexer nos
    // pixels marrons do rosto, que sao o desenho e devem ficar.
    guard sa >= LIMIAR, hu >= 12, hu <= 62 else { continue }
    let (nr, ng, nb) = rgb(alvo, sa, va)
    px[i]     = UInt8(max(0, min(255, nr * al * 255)))
    px[i + 1] = UInt8(max(0, min(255, ng * al * 255)))
    px[i + 2] = UInt8(max(0, min(255, nb * al * 255)))
    tocados += 1
}

guard let saida = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: saida)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: a[2]))
print("  \(URL(fileURLWithPath: a[2]).lastPathComponent): \(tocados) pixels recoloridos")
