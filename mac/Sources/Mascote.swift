import SwiftUI

/// A Fagulha — uma fagulha viva.
///
/// SOBRE O DESENHO
/// ---------------
/// A primeira versão era um quadrado arredondado com duas frestas verticais.
/// Lia como focinho de porco, e com razão: só tinha olhos. Expressão em
/// personagem vem de SOBRANCELHA e BOCA — sem elas, oito estados viram o mesmo
/// boneco pintado de cores diferentes.
///
/// Esta versão tem cinco camadas de expressão, em ordem de quanto cada uma
/// carrega:
///
///   1. sobrancelhas  ângulo e altura. Faz quase todo o trabalho: a mesma
///                    cara com a sobrancelha interna erguida vira preocupação,
///                    e com a externa erguida vira surpresa.
///   2. boca          curvatura e largura.
///   3. olhar         para onde a pupila aponta. Olhar para cima e para o lado
///                    é o gesto universal de "estou pensando".
///   4. abertura      pálpebra. Apertar os olhos lê como concentração.
///   5. corpo         silhueta de chama, que se inclina e estica.
///
/// A silhueta não é mais um quadrado: é uma gota de chama, mais larga embaixo,
/// afinando num topo arredondado, com uma língua de fogo que tremula acima da
/// cabeça. Isso amarra o personagem ao nome.
///
/// Tudo é vetor desenhado em código — nenhum arquivo de imagem. Escala de 20px
/// (na lista de sessões) a 200px sem perder nada, e o mesmo código descreve o
/// boneco da placa.

enum EstadoMascote: String, CaseIterable {
    case ocioso, trabalhando, ferramenta, perguntando
    case esperando, concluido, erro, offline

    init(_ st: String) {
        switch st {
        case "working":  self = .trabalhando
        case "tool":     self = .ferramenta
        case "asking":   self = .perguntando
        case "waiting":  self = .esperando
        case "done":     self = .concluido
        case "error":    self = .erro
        case "offline":  self = .offline
        default:         self = .ocioso
        }
    }

    /// (topo, base) do gradiente do corpo.
    var cores: (Color, Color) {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255)
        }
        switch self {
        case .ocioso:      return (c(242, 156, 92),  c(206, 92, 58))
        case .trabalhando: return (c(250, 168, 84),  c(216, 96, 50))
        case .ferramenta:  return (c(250, 186, 78),  c(214, 118, 44))
        case .perguntando: return (c(198, 152, 246), c(132, 92, 190))
        case .esperando:   return (c(246, 206, 96),  c(206, 152, 48))
        case .concluido:   return (c(112, 220, 154), c(56, 152, 102))
        case .erro:        return (c(238, 122, 108), c(184, 66, 62))
        case .offline:     return (c(126, 134, 148), c(74, 80, 92))
        }
    }

    var rotulo: String {
        switch self {
        case .ocioso:      return "parado"
        case .trabalhando: return "pensando"
        case .ferramenta:  return "trabalhando"
        case .perguntando: return "te perguntou"
        case .esperando:   return "precisa de você"
        case .concluido:   return "concluiu"
        case .erro:        return "falhou"
        case .offline:     return "sem conexão"
        }
    }

    var temFagulha: Bool { self == .trabalhando || self == .ferramenta }
    var temInterrogacao: Bool { self == .perguntando }
    /// A chama do topo morre quando não há vida do outro lado.
    var temChama: Bool { self != .offline }

    var respiro: Double {
        switch self {
        case .ocioso: return 0.055
        case .trabalhando, .ferramenta: return 0.030
        case .perguntando, .esperando:  return 0.045
        case .concluido: return 0.070
        default: return 0.020
        }
    }

    var periodo: Double {
        switch self {
        case .ocioso: return 3.0
        case .trabalhando, .ferramenta: return 1.6
        case .esperando, .perguntando:  return 1.15
        case .concluido: return 0.9
        default: return 3.6
        }
    }

    var expressao: Expressao {
        switch self {
        case .ocioso:
            return Expressao(sobrancelha: 0, alturaSobrancelha: 0,
                             boca: .sorriso, abertura: 0.92, olhar: .zero)
        case .trabalhando:
            // Olhar para cima e para o lado: o gesto de quem está pensando.
            return Expressao(sobrancelha: -6, alturaSobrancelha: 0.04,
                             boca: .pequena, abertura: 0.85,
                             olhar: CGPoint(x: 0.45, y: -0.5))
        case .ferramenta:
            // Concentrado: olhos apertados, sobrancelha baixa, língua de fora.
            return Expressao(sobrancelha: -16, alturaSobrancelha: -0.05,
                             boca: .lingua, abertura: 0.62, olhar: CGPoint(x: 0, y: 0.15))
        case .perguntando:
            // Sobrancelha externa erguida = surpresa/pergunta. Boca em "o".
            return Expressao(sobrancelha: 14, alturaSobrancelha: 0.10,
                             boca: .o, abertura: 1.05, olhar: CGPoint(x: 0, y: -0.1))
        case .esperando:
            return Expressao(sobrancelha: 20, alturaSobrancelha: 0.08,
                             boca: .ondulada, abertura: 1.0, olhar: CGPoint(x: 0, y: 0.1))
        case .concluido:
            // Olhos fechados em arco para cima — o sorriso de olhos.
            return Expressao(sobrancelha: 8, alturaSobrancelha: 0.06,
                             boca: .sorrisoGrande, abertura: 0, olhar: .zero,
                             olhosFelizes: true)
        case .erro:
            // Sobrancelha INTERNA erguida: preocupação, não raiva.
            return Expressao(sobrancelha: -22, alturaSobrancelha: 0.02,
                             boca: .ondulada, abertura: 0.75, olhar: CGPoint(x: 0, y: 0.25),
                             invertida: true)
        case .offline:
            return Expressao(sobrancelha: 0, alturaSobrancelha: -0.03,
                             boca: .reta, abertura: 0.12, olhar: .zero)
        }
    }
}

struct Expressao {
    /// Graus. Positivo levanta a ponta EXTERNA (surpresa); negativo abaixa
    /// (concentração). Com `invertida`, quem sobe é a ponta interna, que é a
    /// diferença entre parecer bravo e parecer preocupado.
    var sobrancelha: Double
    var alturaSobrancelha: Double
    var boca: Boca
    /// 1 = olho normal. 0 = fechado.
    var abertura: Double
    /// Direção da pupila, -1 a 1 em cada eixo.
    var olhar: CGPoint
    var olhosFelizes: Bool = false
    var invertida: Bool = false
}

enum Boca { case sorriso, sorrisoGrande, pequena, o, reta, ondulada, lingua }

/// Quanto a moldura é maior que o corpo, para caber a chama, a fagulha em
/// órbita e as interrogações sem cortar.
private let FOLGA: CGFloat = 1.42

struct Mascote: View {
    let estado: EstadoMascote
    var lado: CGFloat = 64

    @ViewBuilder
    var body: some View {
        // Arte do usuário tem precedência. O vetor é o padrão de fábrica, não
        // o caminho principal — e continua sendo a rede de segurança quando
        // falta algum estado.
        if let img = Sprites.imagem(estado) {
            MascoteSprite(estado: estado, imagem: img, lado: lado * FOLGA)
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Canvas { g, tam in desenhar(&g, tam, t) }
                    .frame(width: lado * FOLGA, height: lado * FOLGA)
            }
            .accessibilityLabel("mascote: \(estado.rotulo)")
        }
    }

    // MARK: - silhueta

    /// Gota de chama: base larga e arredondada, afinando num topo suave.
    /// Nada de círculo nem de quadrado — a silhueta é a primeira coisa que
    /// se reconhece num personagem, antes de qualquer detalhe.
    private func corpoPath(_ r: CGRect, esticar: Double) -> Path {
        let w = r.width
        let h = r.height * (1 + esticar)
        let cx = r.midX
        let topo = r.maxY - h
        var p = Path()
        p.move(to: CGPoint(x: cx, y: topo))
        // lado esquerdo, descendo
        p.addCurve(to: CGPoint(x: cx - w * 0.50, y: topo + h * 0.60),
                   control1: CGPoint(x: cx - w * 0.30, y: topo + h * 0.02),
                   control2: CGPoint(x: cx - w * 0.50, y: topo + h * 0.28))
        // base esquerda, arredondando
        p.addCurve(to: CGPoint(x: cx, y: r.maxY),
                   control1: CGPoint(x: cx - w * 0.50, y: r.maxY - h * 0.02),
                   control2: CGPoint(x: cx - w * 0.26, y: r.maxY))
        // base direita
        p.addCurve(to: CGPoint(x: cx + w * 0.50, y: topo + h * 0.60),
                   control1: CGPoint(x: cx + w * 0.26, y: r.maxY),
                   control2: CGPoint(x: cx + w * 0.50, y: r.maxY - h * 0.02))
        // lado direito, subindo
        p.addCurve(to: CGPoint(x: cx, y: topo),
                   control1: CGPoint(x: cx + w * 0.50, y: topo + h * 0.28),
                   control2: CGPoint(x: cx + w * 0.30, y: topo + h * 0.02))
        p.closeSubpath()
        return p
    }

    /// A fagulha que flutua acima da cabeça.
    ///
    /// Na primeira versão ela nascia colada no topo e usava a cor do corpo.
    /// O resultado foi um cabinho marrom: o boneco virou abóbora. Duas coisas
    /// consertam isso, e as duas são sobre como fogo funciona.
    ///
    /// Primeiro, fogo é MAIS CLARO que o que ilumina — núcleo quase branco,
    /// não a mesma tinta do corpo. Segundo, chama tem barriga: alarga um
    /// pouco antes de afinar na ponta, e a ponta pende para um lado. Cone
    /// simétrico lê como talo de planta.
    ///
    /// Ela também flutua com uma folga acima da cabeça, em vez de brotar
    /// dela — assim é companheira, não caule.
    private func chamaPath(_ cx: CGFloat, _ base: CGFloat, _ d: CGFloat,
                           _ f: Double) -> Path {
        let alt = d * (0.21 + 0.045 * f)
        let lar = d * (0.115 + 0.012 * f)
        let pende = CGFloat(f) * d * 0.045      // a ponta balança
        var p = Path()
        p.move(to: CGPoint(x: cx, y: base))
        // sobe pela esquerda, com barriga
        p.addCurve(to: CGPoint(x: cx + pende, y: base - alt),
                   control1: CGPoint(x: cx - lar * 1.15, y: base - alt * 0.18),
                   control2: CGPoint(x: cx - lar * 0.72, y: base - alt * 0.74))
        // desce pela direita
        p.addCurve(to: CGPoint(x: cx, y: base),
                   control1: CGPoint(x: cx + lar * 0.78, y: base - alt * 0.72),
                   control2: CGPoint(x: cx + lar * 1.15, y: base - alt * 0.16))
        p.closeSubpath()
        return p
    }

    // MARK: - desenho

    private func desenhar(_ g: inout GraphicsContext, _ tam: CGSize, _ t: TimeInterval) {
        let d = lado
        let e = estado.expressao
        let (topo, base) = estado.cores

        let corpo = CGRect(x: (tam.width - d) / 2, y: (tam.height - d) / 2 + d * 0.06,
                           width: d, height: d * 0.94)

        // respiração: estica e encolhe o corpo inteiro (squash & stretch)
        let fase = sin(t / estado.periodo * 2 * .pi)
        let esticar = fase * estado.respiro

        // piscada
        let ciclo = 4.2 + Double(abs(estado.hashValue) % 5) * 0.6
        let p = (t.truncatingRemainder(dividingBy: ciclo)) / ciclo
        let piscando = p > 0.972 && e.abertura > 0.2
        let abertura = piscando ? 0.06 : e.abertura * (1 + fase * 0.05)

        // —— chama do topo
        if estado.temChama {
            let flick = sin(t * 7.3) * 0.5 + sin(t * 4.1) * 0.5
            let cimaCorpo = corpo.maxY - corpo.height * (1 + esticar)
            let baseChama = cimaCorpo - d * 0.05        // flutua, não brota
            let ch = chamaPath(corpo.midX, baseChama, d, flick)
            // halo: o que faz o desenho parecer luz em vez de recorte
            g.fill(ch.applying(CGAffineTransform(translationX: 0, y: 0)),
                   with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.35).opacity(0.30),
                                      .clear]),
                    center: CGPoint(x: corpo.midX, y: baseChama - d * 0.10),
                    startRadius: 0, endRadius: d * 0.26))
            g.fill(ch, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.98, blue: 0.86),
                                  Color(red: 1.0, green: 0.82, blue: 0.32),
                                  Color(red: 0.99, green: 0.55, blue: 0.18)]),
                startPoint: CGPoint(x: corpo.midX, y: baseChama - d * 0.24),
                endPoint: CGPoint(x: corpo.midX, y: baseChama)))
        }

        // —— corpo
        let silhueta = corpoPath(corpo, esticar: esticar)
        g.fill(silhueta, with: .linearGradient(
            Gradient(colors: [topo, base]),
            startPoint: CGPoint(x: corpo.midX, y: corpo.minY),
            endPoint: CGPoint(x: corpo.midX, y: corpo.maxY)))
        // luz de cima, para o corpo não ler como recorte chapado
        g.fill(silhueta, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.22), .clear]),
            center: CGPoint(x: corpo.midX - d * 0.14, y: corpo.minY + d * 0.16),
            startRadius: 0, endRadius: d * 0.55))

        // geometria do rosto
        let alturaReal = corpo.height * (1 + esticar)
        let olhoY = corpo.maxY - alturaReal * 0.52
        let sep = d * 0.185
        let rOlho = d * 0.125

        // —— olhos
        for (i, dx) in [-sep, sep].enumerated() {
            let cx = corpo.midX + dx
            if e.olhosFelizes {
                // arco para cima: o sorriso que mora nos olhos
                var arco = Path()
                arco.addArc(center: CGPoint(x: cx, y: olhoY + rOlho * 0.35),
                            radius: rOlho * 0.95,
                            startAngle: .degrees(200), endAngle: .degrees(340),
                            clockwise: false)
                g.stroke(arco, with: .color(.black.opacity(0.72)),
                         style: StrokeStyle(lineWidth: d * 0.045, lineCap: .round))
                continue
            }

            let alt = rOlho * 2 * abertura
            let branco = CGRect(x: cx - rOlho, y: olhoY - alt / 2,
                                width: rOlho * 2, height: max(d * 0.02, alt))
            g.fill(Path(ellipseIn: branco), with: .color(.white.opacity(0.97)))

            if abertura > 0.25 {
                // pupila: segue o olhar, presa dentro do branco
                let px = cx + e.olhar.x * rOlho * 0.40
                let py = olhoY + e.olhar.y * rOlho * 0.34 * abertura
                let rp = rOlho * 0.52
                g.fill(Path(ellipseIn: CGRect(x: px - rp, y: py - rp,
                                              width: rp * 2, height: rp * 2)),
                       with: .color(Color(red: 0.10, green: 0.07, blue: 0.09)))
                // brilho: o ponto que separa "olho vivo" de "buraco preto"
                let rb = rOlho * 0.20
                g.fill(Path(ellipseIn: CGRect(x: px - rp * 0.45 - rb / 2,
                                              y: py - rp * 0.45 - rb / 2,
                                              width: rb * 2, height: rb * 2)),
                       with: .color(.white.opacity(0.92)))
            }
            _ = i
        }

        // —— sobrancelhas: onde mora a maior parte da expressão
        if estado.temChama {
            for dx in [-sep, sep] {
                let externa = dx < 0 ? -1.0 : 1.0
                let giro = (e.invertida ? -externa : externa) * e.sobrancelha
                let cx = corpo.midX + dx
                let cy = olhoY - rOlho * 1.55 - CGFloat(e.alturaSobrancelha) * d
                let lar = rOlho * 1.7
                var s = Path()
                s.move(to: CGPoint(x: -lar / 2, y: 0))
                s.addQuadCurve(to: CGPoint(x: lar / 2, y: 0),
                               control: CGPoint(x: 0, y: -lar * 0.22))
                let tr = CGAffineTransform(translationX: cx, y: cy)
                    .rotated(by: .pi / 180 * giro)
                g.stroke(s.applying(tr), with: .color(.black.opacity(0.55)),
                         style: StrokeStyle(lineWidth: d * 0.042, lineCap: .round))
            }
        }

        // —— boca
        desenharBoca(&g, e.boca, corpo, olhoY + rOlho * 2.1, d, t)

        // —— bochechas
        if estado.temChama {
            for dx in [-sep * 1.75, sep * 1.75] {
                let rb = d * 0.075
                g.fill(Path(ellipseIn: CGRect(x: corpo.midX + dx - rb,
                                              y: olhoY + rOlho * 1.1 - rb * 0.6,
                                              width: rb * 2, height: rb * 1.2)),
                       with: .color(.white.opacity(0.16)))
            }
        }

        // —— fagulha em órbita
        if estado.temFagulha {
            let ang = t * 2.0
            let raio = d * 0.62
            let fx = corpo.midX + cos(ang) * raio
            let fy = corpo.midY + sin(ang) * raio * 0.46
            let s = d * 0.10
            g.fill(Path(ellipseIn: CGRect(x: fx - s / 2, y: fy - s / 2,
                                          width: s, height: s)),
                   with: .color(topo))
            g.fill(Path(ellipseIn: CGRect(x: fx - s * 0.9, y: fy - s * 0.9,
                                          width: s * 1.8, height: s * 1.8)),
                   with: .color(topo.opacity(0.20)))
        }

        // —— interrogações
        if estado.temInterrogacao {
            for i in 0..<3 {
                let f = ((t + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.7)) / 1.7
                let y = corpo.minY - d * 0.04 - CGFloat(f) * d * 0.16
                let opa = f < 0.25 ? f / 0.25 : (1 - f) / 0.75
                g.opacity = opa
                g.draw(Text("?").font(.system(size: d * 0.26, weight: .heavy))
                        .foregroundStyle(topo),
                       at: CGPoint(x: corpo.midX + (Double(i) - 1) * d * 0.26, y: y))
                g.opacity = 1
            }
        }
    }

    private func desenharBoca(_ g: inout GraphicsContext, _ b: Boca,
                              _ corpo: CGRect, _ y: CGFloat, _ d: CGFloat,
                              _ t: TimeInterval) {
        let cx = corpo.midX
        let escuro = Color.black.opacity(0.62)
        let traco = StrokeStyle(lineWidth: d * 0.045, lineCap: .round)

        switch b {
        case .sorriso, .sorrisoGrande:
            let lar = d * (b == .sorrisoGrande ? 0.30 : 0.20)
            let prof = d * (b == .sorrisoGrande ? 0.14 : 0.075)
            var p = Path()
            p.move(to: CGPoint(x: cx - lar / 2, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + lar / 2, y: y),
                           control: CGPoint(x: cx, y: y + prof * 2))
            if b == .sorrisoGrande {
                p.closeSubpath()
                g.fill(p, with: .color(escuro))
            } else {
                g.stroke(p, with: .color(escuro), style: traco)
            }

        case .pequena:
            var p = Path()
            p.move(to: CGPoint(x: cx - d * 0.055, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + d * 0.055, y: y),
                           control: CGPoint(x: cx, y: y + d * 0.05))
            g.stroke(p, with: .color(escuro), style: traco)

        case .o:
            let r = d * 0.062
            g.fill(Path(ellipseIn: CGRect(x: cx - r, y: y - r * 0.8,
                                          width: r * 2, height: r * 2.1)),
                   with: .color(escuro))

        case .reta:
            var p = Path()
            p.move(to: CGPoint(x: cx - d * 0.08, y: y))
            p.addLine(to: CGPoint(x: cx + d * 0.08, y: y))
            g.stroke(p, with: .color(escuro), style: traco)

        case .ondulada:
            // Boca em zigue-zague: o desenho universal de desconforto.
            var p = Path()
            let lar = d * 0.20, passos = 4
            p.move(to: CGPoint(x: cx - lar / 2, y: y))
            for i in 1...passos {
                let x = cx - lar / 2 + lar * CGFloat(i) / CGFloat(passos)
                let dy = (i % 2 == 0 ? 1.0 : -1.0) * d * 0.028
                p.addQuadCurve(to: CGPoint(x: x, y: y),
                               control: CGPoint(x: x - lar / CGFloat(passos) / 2,
                                                y: y + dy))
            }
            g.stroke(p, with: .color(escuro), style: traco)

        case .lingua:
            var p = Path()
            p.move(to: CGPoint(x: cx - d * 0.09, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + d * 0.09, y: y),
                           control: CGPoint(x: cx, y: y + d * 0.06))
            g.stroke(p, with: .color(escuro), style: traco)
            // pontinha da língua, no canto — sinal de concentração
            let lr = d * 0.045
            let bal = CGFloat(sin(t * 3)) * d * 0.008
            g.fill(Path(ellipseIn: CGRect(x: cx + d * 0.035 + bal, y: y + d * 0.012,
                                          width: lr * 1.6, height: lr * 1.8)),
                   with: .color(Color(red: 0.95, green: 0.45, blue: 0.48)))
        }
    }
}
