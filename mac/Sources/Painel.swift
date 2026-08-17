import SwiftUI
import ServiceManagement

/// Cores dos estados — as mesmas do mascote na placa, pra você não ter que
/// aprender dois vocabulários visuais pra mesma informação.
enum Paleta {
    static func estado(_ nome: String) -> Color {
        switch nome {
        case "trabalhando": return Color(red: 0.98, green: 0.55, blue: 0.20)
        case "perguntando": return Color(red: 0.65, green: 0.45, blue: 0.95)
        case "esperando":   return Color(red: 0.91, green: 0.76, blue: 0.35)
        case "concluido":   return Color(red: 0.37, green: 0.81, blue: 0.56)
        case "erro":        return Color(red: 0.91, green: 0.38, blue: 0.29)
        default:            return Color.secondary
        }
    }

    static func severidade(_ s: String) -> Color {
        switch s {
        case "warning":  return Color(red: 0.91, green: 0.76, blue: 0.35)
        case "critical": return Color(red: 0.91, green: 0.38, blue: 0.29)
        default:         return Color(red: 0.37, green: 0.81, blue: 0.56)
        }
    }
}

struct Cabecalho: View {
    let titulo: String
    var body: some View {
        Text(titulo.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.6)
    }
}

struct BarraLimite: View {
    let limite: Limite
    let confiavel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(limite.l)
                    .font(.system(size: 11, weight: limite.a ? .semibold : .regular))
                Spacer(minLength: 4)
                Text("\(limite.p)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(confiavel ? .primary : .tertiary)
                Text(limite.r)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Paleta.severidade(limite.s).opacity(confiavel ? 1 : 0.35))
                        .frame(width: max(2, g.size.width * CGFloat(limite.p) / 100))
                }
            }
            .frame(height: 4)
        }
    }
}

struct LinhaSessao: View {
    let s: Sessao
    var body: some View {
        HStack(spacing: 7) {
            // Um mascote por sessão, igual à placa. Bolinha colorida exigia
            // decorar o código de cores; o boneco você lê direto.
            Mascote(estado: EstadoMascote(s.st), lado: 20)
            Text(s.pj.isEmpty ? "—" : s.pj)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(s.dt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(s.age)s")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

struct Painel: View {
    @ObservedObject var bridge: Bridge
    @State private var abrirNoLogin = SMAppService.mainApp.status == .enabled
    @State private var erroLogin: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topo

            if let d = bridge.dados {
                if d.rede_aberta == true { avisoRede }
                if let j = d.janelas, j.ok { consumoJanelas(j) }
                if !d.limites.isEmpty { limites(d) }
                consumo(d)
                sessoes(d)
                placa(d)
            } else if bridge.estado.vivo {
                Text("consultando o bridge…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let e = bridge.erroConsulta, bridge.estado.vivo {
                Text(e).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }

            Divider()
            rodape
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - blocos

    /// O mascote é a primeira coisa do painel de propósito: o estado das suas
    /// sessões deve ser legível antes de qualquer número, e num relance.
    private var topo: some View {
        HStack(spacing: 10) {
            Mascote(estado: bridge.estado.vivo
                    ? (bridge.dados?.estadoDominante ?? .ocioso) : .offline,
                    lado: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fagulha").font(.system(size: 13, weight: .semibold))
                Text(bridge.estado.vivo
                     ? (bridge.dados?.estadoDominante ?? .ocioso).rotulo
                     : bridge.estado.descricao)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let n = bridge.dados?.sessoes.count, n > 1 {
                Text("\(n) sessões")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Modo aberto é temporário por natureza — dura até a placa ser regravada
    /// com o token. Sem este aviso ele vira permanente por esquecimento, e o
    /// custo é o consumo e os nomes dos seus projetos legíveis por qualquer um
    /// na mesma rede.
    private var avisoRede: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Paleta.severidade("warning"))
            Text("Rede aberta: qualquer um no seu WiFi lê estes dados. "
                 + "Regrave a placa para fechar.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .background(Paleta.severidade("warning").opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func limites(_ d: AppEstado) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Cabecalho(titulo: "Limites da assinatura")
                Spacer()
                if !d.limitesConfiaveis && d.limites_age_s >= 0 {
                    // O número velho continua visível, mas rotulado. Esconder
                    // seria pior: você não saberia que existe.
                    Text("cache de \(idadeCurta(d.limites_age_s))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Paleta.severidade("warning"))
                }
            }
            ForEach(d.limites) { BarraLimite(limite: $0, confiavel: d.limitesConfiaveis) }
        }
    }

    /// Consumo calculado aqui, dos transcripts. Fica ACIMA dos limites da
    /// assinatura de propósito: este número é sempre atual, aquele depende de
    /// um cache que o Claude Code às vezes deixa envelhecer dias.
    @ViewBuilder
    private func consumoJanelas(_ j: Janelas) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Cabecalho(titulo: "Consumo · sempre atual")
            if let s = j.sessao { faixa("Sessão 5h", s) }
            if let s = j.semana { faixa("Semana 7d", s) }
            if let dias = j.historico_d {
                Text("comparado ao seu próprio pico em \(Int(dias)) dias")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func faixa(_ nome: String, _ f: Faixa) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(nome).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Text("\(f.reqs) reqs · \(compacto(f.saida))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                if f.comparavel {
                    Text("\(f.pct)%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if f.comparavel {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Paleta.estado("trabalhando"))
                            .frame(width: max(2, g.size.width
                                              * CGFloat(min(f.pct, 100)) / 100))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func consumo(_ d: AppEstado) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Cabecalho(titulo: "Hoje")
            HStack(spacing: 14) {
                metrica("\(d.uso.requests ?? 0)", "requests")
                metrica(compacto(d.uso.output), "saída")
                metrica(compacto(d.uso.cache_read), "cache")
            }
        }
    }

    private func metrica(_ valor: String, _ nome: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(valor).font(.system(size: 14, weight: .semibold).monospacedDigit())
            Text(nome).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func sessoes(_ d: AppEstado) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Cabecalho(titulo: d.sessoes.isEmpty
                      ? "Nenhuma sessão ativa" : "Sessões ativas")
            ForEach(d.sessoes) { LinhaSessao(s: $0) }
        }
    }

    private func placa(_ d: AppEstado) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(d.placaViva ? Paleta.estado("concluido") : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text("Waveshare").font(.system(size: 11, weight: .medium))
            Spacer()
            Text(d.placa_age_s < 0 ? "nunca apareceu"
                 : d.placaViva ? d.placa_ip
                 : "sumiu há \(idadeCurta(d.placa_age_s))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var rodape: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $abrirNoLogin) {
                Text("Abrir no login").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .onChange(of: abrirNoLogin) { _, novo in aplicarLogin(novo) }

            Toggle(isOn: $bridge.flutuante) {
                Text("Mascote na área de trabalho").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("Deixa os mascotes soltos na tela, sempre visíveis. "
                  + "Arraste para posicionar.")

            Toggle(isOn: $bridge.buscarLimites) {
                Text("Buscar limites reais").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("Pede acesso ao chaveiro para ler os limites direto da "
                  + "Anthropic, em vez do cache do Claude Code, que às vezes "
                  + "fica dias sem atualizar.")

            if let e = bridge.erroLimites {
                Text(e).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }

            if let e = erroLogin {
                Text(e).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Button(bridge.estado.vivo ? "Parar bridge" : "Iniciar bridge") {
                    bridge.alternar()
                }
                .font(.system(size: 11))
                Spacer()
                Button("Sair") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 11))
            }
        }
    }

    private func aplicarLogin(_ ligar: Bool) {
        do {
            if ligar { try SMAppService.mainApp.register() }
            else     { try SMAppService.mainApp.unregister() }
            erroLogin = nil
        } catch {
            // Falha comum: app não assinado ou fora de /Applications.
            // Dizemos o motivo em vez de deixar a caixinha mentindo.
            erroLogin = "não deu: \(error.localizedDescription)"
            abrirNoLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
