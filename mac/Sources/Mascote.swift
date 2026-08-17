import SwiftUI

/// O mascote, desenhado em SwiftUI.
///
/// É o MESMO boneco da placa, não um primo. As proporções, as cores e o jeito
/// de animar saíram de firmware/main/ui.c, onde ele é desenhado com primitivas
/// do LVGL. Manter uma identidade só é o ponto: quem olha o visor e quem olha
/// a barra de menu tem que reconhecer a mesma coisa.
///
/// Duas escolhas herdadas da placa, e vale saber por quê:
///
///   A respiração vai nos OLHOS, não no corpo. Lá isso existia porque mexer no
///   corpo invalidava a área toda e o painel entregava a repintura em faixas,
///   desenhando costuras visíveis. Aqui não haveria esse custo — mas o gesto
///   virou parte do personagem, e mudar faria os dois parecerem bonecos
///   diferentes.
///
///   A cor troca direto, sem interpolar. Mesma história: na placa cada passo
///   da interpolação era uma varredura de tela.

enum EstadoMascote: String, CaseIterable {
    case ocioso, trabalhando, ferramenta, perguntando
    case esperando, concluido, erro, offline

    /// Converte o campo `st` que vem do bridge.
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

    /// (topo, base) do gradiente — os mesmos valores de COR[] no ui.c.
    var cores: (Color, Color) {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255)
        }
        switch self {
        case .ocioso, .trabalhando: return (c(232, 132, 90),  c(176, 78, 52))
        case .ferramenta:           return (c(232, 152, 82),  c(172, 96, 44))
        case .perguntando:          return (c(186, 142, 234), c(122, 84, 172))
        case .esperando:            return (c(232, 193, 90),  c(168, 132, 48))
        case .concluido:            return (c(95, 207, 142),  c(52, 132, 90))
        case .erro:                 return (c(96, 150, 205),  c(58, 96, 140))
        case .offline:              return (c(90, 99, 112),   c(52, 58, 68))
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

    /// A fagulha só orbita quando há trabalho acontecendo. Parada, ela seria
    /// enfeite; girando, ela é a única parte que diz "isto está em movimento".
    var temFagulha: Bool { self == .trabalhando || self == .ferramenta }

    /// Interrogações subindo — o estado em que a bola está com você.
    var temInterrogacao: Bool { self == .perguntando }

    /// Amplitude da respiração, em fração da altura do olho.
    var respiro: Double {
        switch self {
        case .ocioso:      return 0.30
        case .trabalhando, .ferramenta: return 0.16
        case .perguntando, .esperando:  return 0.22
        default:           return 0.12
        }
    }

    /// Ciclo de respiração. Ansioso respira rápido.
    var periodo: Double {
        switch self {
        case .ocioso:                    return 2.6
        case .trabalhando, .ferramenta:  return 1.5
        case .esperando, .perguntando:   return 1.1
        default:                         return 3.0
        }
    }
}

/// Quanto a moldura é maior que o corpo, para caber a órbita da fagulha e as
/// interrogações sem cortar.
private let FOLGA: CGFloat = 1.36

struct Mascote: View {
    let estado: EstadoMascote
    var lado: CGFloat = 64

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { ctx, tam in desenhar(&ctx, tam, t) }
                // Folga nos DOIS eixos. A fagulha orbita a 0.62 do lado a
                // partir do centro, mais o próprio raio: precisa de 1.36x de
                // largura ou ela é cortada fora da moldura — foi o que
                // aconteceu na primeira versão, e o estado "trabalhando"
                // ficava indistinguível de "parado".
                .frame(width: lado * FOLGA, height: lado * FOLGA)
        }
        .accessibilityLabel("mascote: \(estado.rotulo)")
    }

    private func desenhar(_ ctx: inout GraphicsContext, _ tam: CGSize, _ t: TimeInterval) {
        let d = lado
        let ox = (tam.width - d) / 2
        let oy = (tam.height - d) / 2
        let corpo = CGRect(x: ox, y: oy, width: d, height: d)
        let (topo, base) = estado.cores

        // —— corpo
        let forma = Path(roundedRect: corpo, cornerRadius: d * 0.42)
        ctx.fill(forma, with: .linearGradient(
            Gradient(colors: [topo, base]),
            startPoint: CGPoint(x: corpo.midX, y: corpo.minY),
            endPoint: CGPoint(x: corpo.midX, y: corpo.maxY)))

        // —— olhos: respiram e piscam
        let fase = sin(t / estado.periodo * 2 * .pi)
        // Piscada: fecha e abre em ~140ms, a cada ~4s. O deslocamento por
        // estado evita que dois mascotes na tela pisquem em sincronia, que
        // deixa a dupla com cara de enfeite mecânico.
        let ciclo = 4.0 + Double(estado.hashValue % 3) * 0.7
        let p = (t.truncatingRemainder(dividingBy: ciclo)) / ciclo
        let piscando = p > 0.965
        let abertura = piscando ? 0.12 : 1.0 + fase * estado.respiro

        let olhoL = d * 0.135
        let olhoA = d * 0.26 * abertura
        let sep = d * 0.21
        let olhoY = corpo.midY - d * 0.02

        for dx in [-sep, sep] {
            let r = CGRect(x: corpo.midX + dx - olhoL / 2,
                           y: olhoY - olhoA / 2,
                           width: olhoL, height: max(1.5, olhoA))
            ctx.fill(Path(roundedRect: r, cornerRadius: olhoL / 2),
                     with: .color(Color(red: 22 / 255, green: 12 / 255, blue: 8 / 255)))
        }

        // —— fagulha em órbita
        if estado.temFagulha {
            let ang = t * 2.1
            let raio = d * 0.62
            let fx = corpo.midX + cos(ang) * raio
            let fy = corpo.midY + sin(ang) * raio * 0.52
            let s = d * 0.11
            ctx.fill(Path(ellipseIn: CGRect(x: fx - s / 2, y: fy - s / 2,
                                            width: s, height: s)),
                     with: .color(topo))
        }

        // —— interrogações subindo
        if estado.temInterrogacao {
            for i in 0..<3 {
                let atraso = Double(i) * 0.45
                let f = ((t + atraso).truncatingRemainder(dividingBy: 1.6)) / 1.6
                let sobe = corpo.minY - d * 0.02 - f * d * 0.15
                let opa = f < 0.2 ? f / 0.2 : (1 - f) / 0.8
                let x = corpo.midX + (Double(i) - 1) * d * 0.24
                ctx.opacity = opa
                ctx.draw(Text("?")
                    .font(.system(size: d * 0.24, weight: .bold))
                    .foregroundStyle(topo),
                         at: CGPoint(x: x, y: sobe))
                ctx.opacity = 1
            }
        }
    }
}
