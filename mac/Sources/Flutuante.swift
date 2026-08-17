import SwiftUI
import AppKit

/// O mascote solto na área de trabalho, sempre visível.
///
/// A ideia veio do Masko: o boneco não mora dentro de um painel que você abre,
/// ele fica na tela junto com as suas janelas. A diferença é que aqui há um
/// mascote POR SESSÃO ativa, do mesmo jeito que na placa — com quatro sessões
/// rodando, você vê quatro estados de uma vez em vez de um resumo.
///
/// A janela é sem borda, transparente e sem sombra, então o que aparece é só
/// o desenho. Fica no nível .floating: acima das janelas normais, abaixo de
/// menus e alertas do sistema — presente sem atrapalhar.

// MARK: - conteúdo

struct ConteudoFlutuante: View {
    @ObservedObject var bridge: Bridge

    private var sessoes: [Sessao] { bridge.dados?.sessoes ?? [] }

    var body: some View {
        HStack(spacing: 4) {
            if sessoes.isEmpty {
                // Sem sessão o boneco continua ali, parado. Sumir seria mais
                // limpo e menos útil: você perderia a única pista de que o
                // Fagulha está de pé.
                bloco(estado: bridge.estado.vivo ? .ocioso : .offline,
                      titulo: nil, detalhe: nil)
            } else {
                ForEach(sessoes) { s in
                    bloco(estado: EstadoMascote(s.st),
                          titulo: s.pj.isEmpty ? nil : s.pj,
                          detalhe: s.dt.isEmpty ? nil : s.dt)
                }
            }
        }
        .padding(6)
        // Fundo quase invisível, só o bastante para o boneco não sumir sobre
        // um fundo claro e para dar área de arraste em volta dele.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.22))
        )
    }

    private func bloco(estado: EstadoMascote, titulo: String?, detalhe: String?) -> some View {
        VStack(spacing: 1) {
            Mascote(estado: estado, lado: 46)
            if let t = titulo {
                Text(t)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            if let d = detalhe {
                Text(d)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(width: 74)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }
}

// MARK: - janela

final class JanelaFlutuante: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 100),
                   // .nonactivatingPanel: clicar no mascote não rouba o foco
                   // do que você está fazendo. Um boneco de mesa que tira
                   // você do editor seria um estorvo, não um companheiro.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Acompanha você entre desktops e sobrevive a apps em tela cheia.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true   // arrasta pegando em qualquer ponto
        ignoresMouseEvents = false
        // Sem isto o painel some do ar quando o app perde o foco — e o app
        // vive sem foco, porque é LSUIElement.
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Flutuante {
    static let compartilhado = Flutuante()
    private var janela: JanelaFlutuante?

    /// Guarda onde você largou o boneco, para ele voltar ao mesmo lugar.
    private static let posicao = "posicaoFlutuante"

    func mostrar(_ bridge: Bridge) {
        if janela != nil { return }
        let j = JanelaFlutuante()
        let host = NSHostingView(rootView: ConteudoFlutuante(bridge: bridge))
        // A janela se ajusta ao conteúdo: com mais sessões, mais largura.
        host.translatesAutoresizingMaskIntoConstraints = true
        j.contentView = host
        j.setContentSize(host.fittingSize)

        if let s = UserDefaults.standard.string(forKey: Self.posicao) {
            j.setFrameOrigin(NSPointFromString(s))
        } else if let tela = NSScreen.main?.visibleFrame {
            // Estreia no canto inferior direito: longe do menu e da maioria
            // das janelas de trabalho.
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

    /// A janela não redimensiona sozinha quando o número de sessões muda —
    /// NSHostingView cresce, mas a moldura não acompanha. Chamado a cada
    /// atualização de dados.
    func ajustar() {
        guard let j = janela, let host = j.contentView else { return }
        let tam = host.fittingSize
        if abs(j.frame.width - tam.width) > 1 || abs(j.frame.height - tam.height) > 1 {
            // Cresce para a direita e mantém a base: assim o boneco não
            // "pula" quando uma sessão entra ou sai.
            let base = j.frame.origin
            j.setContentSize(tam)
            j.setFrameOrigin(base)
        }
    }
}
