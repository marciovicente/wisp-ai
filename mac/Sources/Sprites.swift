import SwiftUI
import AppKit

/// Carrega mascotes feitos de imagem, de ~/.fagulha/mascotes/<nome>/.
///
/// Existe para o personagem deixar de ser refém do que eu consigo desenhar em
/// código. Vetor procedural escala bem e não pesa nada, mas tem teto: não
/// chega no acabamento de render 3D. Com isto, qualquer arte entra — feita à
/// mão, encomendada ou gerada — e o vetor vira o padrão de fábrica.
///
/// REGRAS
/// ------
/// Um PNG por estado, nomeados como o bridge nomeia os estados. Faltando
/// qualquer um, o conjunto inteiro é ignorado e voltamos ao vetor: melhor um
/// personagem coerente do que sete quadros bonitos e um buraco.
///
/// As imagens são estáticas. O movimento é do código — flutuar, comprimir,
/// inclinar. Num boneco de 46px na área de trabalho, animação quadro a quadro
/// seria trabalho invisível.
enum Sprites {

    static let pasta = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".fagulha/mascotes", isDirectory: true)

    /// Nome do estado como arquivo. São os mesmos nomes que trafegam em
    /// /state, para não haver duas tabelas de tradução no projeto.
    static func arquivo(_ e: EstadoMascote) -> String {
        switch e {
        case .ocioso:      return "idle"
        case .trabalhando: return "working"
        case .ferramenta:  return "tool"
        case .perguntando: return "asking"
        case .esperando:   return "waiting"
        case .concluido:   return "done"
        case .erro:        return "error"
        case .offline:     return "offline"
        }
    }

    /// Qual conjunto usar. Vazio = o vetor embutido.
    static var escolhido: String {
        get { UserDefaults.standard.string(forKey: "mascote") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "mascote")
            cache.removeAll()
            completos.removeAll()
        }
    }

    /// Conjuntos disponíveis: subpastas que tenham os oito estados.
    static func disponiveis() -> [String] {
        guard let itens = try? FileManager.default.contentsOfDirectory(
            at: pasta, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return itens
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .filter { completo($0) }
            .sorted()
    }

    private static var cache: [String: NSImage] = [:]
    private static var completos: [String: Bool] = [:]

    /// Um conjunto só vale se tiver TODOS os estados.
    static func completo(_ nome: String) -> Bool {
        if let c = completos[nome] { return c }
        let base = pasta.appendingPathComponent(nome, isDirectory: true)
        let ok = EstadoMascote.allCases.allSatisfy { e in
            ["png", "PNG"].contains { ext in
                FileManager.default.fileExists(
                    atPath: base.appendingPathComponent("\(arquivo(e)).\(ext)").path)
            }
        }
        completos[nome] = ok
        return ok
    }

    static func imagem(_ e: EstadoMascote) -> Image? {
        let nome = escolhido
        guard !nome.isEmpty, completo(nome) else { return nil }
        let chave = "\(nome)/\(arquivo(e))"
        if let img = cache[chave] { return Image(nsImage: img) }

        let base = pasta.appendingPathComponent(nome, isDirectory: true)
        for ext in ["png", "PNG"] {
            let url = base.appendingPathComponent("\(arquivo(e)).\(ext)")
            if let img = NSImage(contentsOf: url) {
                cache[chave] = img
                return Image(nsImage: img)
            }
        }
        return nil
    }
}

/// O mascote de imagem, com o movimento vindo do código.
///
/// Mesmos gestos do vetor — respiração, comprimir e esticar, uma inclinação
/// de curiosidade — para os dois caminhos parecerem o mesmo personagem em
/// temperamento, não só em forma.
struct MascoteSprite: View {
    let estado: EstadoMascote
    let imagem: Image
    var lado: CGFloat = 64

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let fase = sin(t / estado.periodo * 2 * .pi)

            // Squash & stretch: o volume se conserva, então o que estica na
            // vertical encolhe na horizontal. Sem isso o boneco só "infla".
            let s = 1 + fase * estado.respiro
            // Flutuar acompanha a respiração, meio ciclo atrás — corpo sobe
            // depois de encher, como acontece de verdade.
            let sobe = CGFloat(sin(t / estado.periodo * 2 * .pi - 0.9)) * lado * 0.03
            // Curiosidade e aflição inclinam a cabeça; trabalho não.
            let inclina: Double = {
                switch estado {
                case .perguntando: return sin(t * 1.6) * 5
                case .esperando:   return sin(t * 2.4) * 3
                case .erro:        return -4
                default:           return 0
                }
            }()

            imagem
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: lado, height: lado)
                .scaleEffect(x: 1 / s, y: s, anchor: .bottom)
                .rotationEffect(.degrees(inclina), anchor: .bottom)
                .offset(y: sobe)
                .frame(width: lado * 1.2, height: lado * 1.2)
        }
        .accessibilityLabel("mascote: \(estado.rotulo)")
    }
}
