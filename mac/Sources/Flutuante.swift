import SwiftUI
import AppKit

/// O mascote solto na área de trabalho.
///
/// UM mascote, grande, sem moldura.
///
/// A primeira versão mostrava um boneco por sessão, copiando o que a placa
/// faz. Na mesa isso não funciona: quatro bonecos de 46px numa tela cheia de
/// janelas viram confete, e nenhum deles fica grande o bastante para você ler
/// a expressão de relance — que é a única coisa que o mascote precisa fazer.
///
/// Aqui a divisão é outra. Um personagem grande carrega o ESTADO, um balão
/// diz o QUE está acontecendo, e um contador avisa que há mais de uma sessão.
/// A placa continua dividindo em vários porque lá o espaço é dedicado: a tela
/// inteira é do mascote, e ninguém disputa atenção com ela.
///
/// Sem placa de fundo: com o PNG já recortado, qualquer retângulo atrás vira
/// uma caixa flutuando na sua mesa. O boneco tem que parecer pousado ali.

struct ConteudoFlutuante: View {
    @ObservedObject var bridge: Bridge

    /// Grande de propósito. Era 46px, tamanho em que a cara do personagem
    /// não se lê — e cara que não se lê torna o mascote decoração.
    private let tamanho: CGFloat = 104

    private var sessoes: [Sessao] { bridge.dados?.sessoes ?? [] }

    private var estado: EstadoMascote {
        guard bridge.estado.vivo else { return .offline }
        return bridge.dados?.estadoDominante ?? .ocioso
    }

    /// O que aparece no balão: a sessão mais urgente é quem fala.
    private var fala: (String, String)? {
        guard let d = bridge.dados, !d.sessoes.isEmpty else { return nil }
        let dom = d.estadoDominante
        let s = d.sessoes.first { EstadoMascote($0.st) == dom } ?? d.sessoes[0]
        let que = s.dt.isEmpty ? dom.rotulo : s.dt
        return (que, s.pj)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let (que, projeto) = fala {
                balao(que, projeto)
                    .padding(.bottom, 2)
            }
            ZStack(alignment: .topTrailing) {
                Mascote(estado: estado, lado: tamanho)
                if sessoes.count > 1 { contador }
            }
        }
        .padding(8)
        // Nada de fundo. Ver comentário no topo.
    }

    /// Balão de fala com rabinho apontando para o mascote.
    private func balao(_ que: String, _ projeto: String) -> some View {
        VStack(spacing: 1) {
            Text(que)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !projeto.isEmpty {
                Text(projeto)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            // Rabinho: um triângulo pequeno, deslocado para fora da borda.
            Triangulo()
                .fill(.regularMaterial)
                .frame(width: 12, height: 7)
                .offset(y: 6)
        }
        .fixedSize()
        .frame(maxWidth: 190)
    }

    /// Quantas sessões, quando é mais de uma. Só o número: se você quer
    /// detalhe, o painel da barra tem a lista inteira.
    private var contador: some View {
        Text("\(sessoes.count)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 17, minHeight: 17)
            .background(Circle().fill(Paleta.estado("trabalhando")))
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .offset(x: 2, y: 2)
    }
}

struct Triangulo: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - janela

final class JanelaFlutuante: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                   // .nonactivatingPanel: clicar no mascote não rouba o foco
                   // do que você está fazendo.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        // Sem isto o painel some quando o app perde o foco — e o app vive sem
        // foco, porque é LSUIElement.
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Flutuante {
    static let compartilhado = Flutuante()
    private var janela: JanelaFlutuante?
    private static let posicao = "posicaoFlutuante"

    func mostrar(_ bridge: Bridge) {
        if janela != nil { return }
        let j = JanelaFlutuante()
        let host = NSHostingView(rootView: ConteudoFlutuante(bridge: bridge))
        j.contentView = host
        j.setContentSize(host.fittingSize)

        if let s = UserDefaults.standard.string(forKey: Self.posicao) {
            j.setFrameOrigin(NSPointFromString(s))
        } else if let tela = NSScreen.main?.visibleFrame {
            j.setFrameOrigin(NSPoint(x: tela.maxX - host.fittingSize.width - 28,
                                     y: tela.minY + 28))
        }
        j.orderFrontRegardless()
        janela = j
    }

    func esconder() {
        guardarPosicao()
        janela?.orderOut(nil)
        janela = nil
    }

    func guardarPosicao() {
        guard let j = janela else { return }
        UserDefaults.standard.set(NSStringFromPoint(j.frame.origin), forKey: Self.posicao)
    }

    /// O balão muda de largura conforme o texto, e a moldura não acompanha
    /// sozinha. Mantemos o canto INFERIOR ESQUERDO fixo: assim o mascote fica
    /// parado no lugar e é o balão que cresce para cima, em vez de o boneco
    /// escorregar pela mesa a cada troca de ferramenta.
    func ajustar() {
        guard let j = janela, let host = j.contentView else { return }
        let tam = host.fittingSize
        guard abs(j.frame.width - tam.width) > 1 || abs(j.frame.height - tam.height) > 1
        else { return }
        let base = NSPoint(x: j.frame.minX, y: j.frame.minY)
        j.setContentSize(tam)
        j.setFrameOrigin(base)
    }
}
