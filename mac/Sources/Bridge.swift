import Foundation
import Combine

/// Dono do processo do bridge e da consulta de estado.
///
/// DUAS DECISÕES QUE VALEM EXPLICAÇÃO
///
/// 1. Roda com /usr/bin/python3, o Python 3.9 que vem com o macOS — nunca
///    com o do asdf. O bridge foi escrito só com a biblioteca padrão e
///    recebeu `from __future__ import annotations` justamente pra caber no
///    3.9. Assim o app não quebra no dia em que você trocar de versão.
///
/// 2. Se já houver um bridge de pé na porta, o app ADOTA em vez de tentar
///    subir outro e falhar com "endereço em uso". Quem sobe pelo terminal
///    durante o desenvolvimento continua funcionando com o app aberto.
@MainActor
final class Bridge: ObservableObject {

    enum Estado: Equatable {
        case parado
        case subindo
        case rodando      // processo nosso
        case adotado      // já estava de pé, não fomos nós
        case falhou(String)

        var descricao: String {
            switch self {
            case .parado:          return "parado"
            case .subindo:         return "subindo…"
            case .rodando:         return "rodando"
            case .adotado:         return "rodando (externo)"
            case .falhou(let m):   return "falhou: \(m)"
            }
        }

        var vivo: Bool {
            if case .rodando = self { return true }
            if case .adotado = self { return true }
            return false
        }
    }

    static let porta = 4666

    /// Instância única. Existe pra que o delegado do NSApplication consiga
    /// derrubar o bridge no encerramento sem que a App precise passar a
    /// referência pra ele — SwiftUI não dá um gancho bom pra isso.
    static let compartilhado = Bridge()

    @Published private(set) var estado: Estado = .parado
    @Published private(set) var dados: AppEstado?
    /// Última falha de consulta, pra o painel não mentir silêncio.
    @Published private(set) var erroConsulta: String?
    /// Última falha ao buscar os limites reais. nil = deu certo.
    @Published private(set) var erroLimites: String?

    /// Buscar os limites direto da Anthropic (pede acesso ao chaveiro).
    /// Desligando, o app volta a usar só o cache do Claude Code em disco.
    @Published var buscarLimites: Bool = UserDefaults.standard
        .object(forKey: "buscarLimites") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(buscarLimites, forKey: "buscarLimites")
            if buscarLimites { Task { await atualizarLimites() } }
        }
    }

    /// Mesmo intervalo que o Claude Code usa no cache dele. Buscar mais que
    /// isso não traz número novo, só gasta requisição.
    private static let intervaloLimites: TimeInterval = 300

    private var proc: Process?
    private var pedidoDeParar = false
    private var timer: Timer?
    private var timerLimites: Timer?
    private var tentativas = 0

    private var base: URL { URL(string: "http://127.0.0.1:\(Self.porta)")! }

    /// server.py vai embarcado no bundle: o app é autocontido e pode ser
    /// movido pra /Applications sem levar o repositório junto.
    private var scriptURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bridge", isDirectory: true)
            .appendingPathComponent("server.py")
    }

    // MARK: - ciclo de vida

    func iniciar() {
        pedidoDeParar = false
        estado = .subindo

        Task {
            // Alguém já está servindo? Então é dele o processo, não nosso.
            if await responde() {
                estado = .adotado
                comecarConsulta()
                return
            }
            subirProcesso()
        }
    }

    private func subirProcesso() {
        guard let script = scriptURL,
              FileManager.default.fileExists(atPath: script.path) else {
            estado = .falhou("server.py não veio no bundle")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, "\(Self.porta)"]
        p.currentDirectoryURL = script.deletingLastPathComponent()
        // Sem herdar o terminal: o app pode ser iniciado pelo Finder.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        // Rede de segurança contra órfão: o bridge vigia este PID e se encerra
        // se o app sumir. Cobre force-quit e crash, onde nenhum código nosso
        // de saída chega a rodar.
        var env = ProcessInfo.processInfo.environment
        env["FAGULHA_PAI"] = "\(ProcessInfo.processInfo.processIdentifier)"
        p.environment = env

        p.terminationHandler = { [weak self] encerrado in
            Task { @MainActor in
                self?.processoMorreu(status: encerrado.terminationStatus)
            }
        }

        do {
            try p.run()
            proc = p
            estado = .rodando
            comecarConsulta()
        } catch {
            estado = .falhou(error.localizedDescription)
        }
    }

    private func processoMorreu(status: Int32) {
        proc = nil
        pararConsulta()

        if pedidoDeParar {
            estado = .parado
            return
        }

        // Morreu sozinho: tenta de novo, com espera crescente pra não
        // entrar em loop apertado se o defeito for permanente.
        tentativas += 1
        guard tentativas <= 5 else {
            estado = .falhou("morreu \(tentativas)x, desisti")
            return
        }
        let espera = Double(min(tentativas * 2, 30))
        estado = .falhou("caiu (status \(status)), voltando em \(Int(espera))s")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000))
            if !pedidoDeParar { iniciar() }
        }
    }

    func parar() {
        pedidoDeParar = true
        pararConsulta()
        // Adotado não é nosso pra matar — quem subiu é que derruba.
        if case .adotado = estado {
            estado = .parado
            dados = nil
            return
        }
        proc?.terminate()
        proc = nil
        estado = .parado
        dados = nil
    }

    func alternar() {
        estado.vivo ? parar() : { tentativas = 0; iniciar() }()
    }

    // MARK: - consulta

    /// Busca os limites reais e entrega ao bridge.
    ///
    /// A primeira chamada faz o macOS pedir sua autorização para ler a
    /// credencial do Claude Code. Se você recusar, DESLIGAMOS a opção — pedir
    /// de novo a cada 5 minutos seria assédio, e "não" é uma resposta.
    private func atualizarLimites() async {
        guard buscarLimites, estado.vivo else { return }
        do {
            let u = try await Limites.buscar()
            await Limites.entregar(u, porta: Self.porta)
            erroLimites = nil
        } catch let f as Limites.Falha {
            erroLimites = f.descricao
            await Limites.reportarFalha(f.descricao, porta: Self.porta)
            if case .semCredencial(let s) = f, s == errSecUserCanceled {
                buscarLimites = false
            }
        } catch {
            erroLimites = error.localizedDescription
        }
    }

    private func comecarLimites() {
        timerLimites?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.intervaloLimites,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.atualizarLimites() }
        }
        RunLoop.main.add(t, forMode: .common)
        timerLimites = t
        Task { await atualizarLimites() }
    }

    private func comecarConsulta() {
        tentativas = 0
        pararConsulta()
        comecarLimites()
        // 2s: o painel só fica visível quando aberto, e nada aqui muda
        // rápido o bastante pra justificar mais.
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.consultar() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await consultar() }
    }

    private func pararConsulta() {
        timer?.invalidate()
        timer = nil
        timerLimites?.invalidate()
        timerLimites = nil
    }

    private func responde() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func consultar() async {
        var req = URLRequest(url: base.appendingPathComponent("app"))
        req.timeoutInterval = 4
        do {
            let (raw, _) = try await URLSession.shared.data(for: req)
            dados = try JSONDecoder().decode(AppEstado.self, from: raw)
            erroConsulta = nil
        } catch {
            erroConsulta = error.localizedDescription
        }
    }

    /// Texto curto pro ícone da barra. Prioriza o limite que mais aperta,
    /// porque é a informação pela qual você olharia pra lá.
    var rotuloBarra: String {
        guard estado.vivo else { return "—" }
        guard let d = dados else { return "…" }
        if d.pico >= 0 { return "\(d.pico)%" }
        let ativas = d.sessoes.count
        return ativas > 0 ? "\(ativas)" : "·"
    }
}
