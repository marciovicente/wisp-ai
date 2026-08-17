import Foundation

/// Espelha o payload de GET /app do bridge.
///
/// Os nomes curtos (`st`, `dt`, `pj`) vêm de /state, que foi desenhado pra um
/// ESP32 parseando JSON com pouca RAM. O app carrega os mesmos nomes em vez de
/// traduzir no meio do caminho: um formato só, um lugar só pra errar.

struct Sessao: Decodable, Identifiable {
    let st: String      // estado: idle/working/tool/asking/waiting/done/error
    let dt: String      // detalhe: "Bash", "approve plan"…
    let pj: String      // projeto
    let md: String      // modelo
    let age: Int        // segundos desde o último evento

    var id: String { "\(pj)|\(st)|\(dt)|\(age)" }

    /// Cor do pontinho. Mesma semântica do mascote na placa.
    var cor: String {
        switch st {
        case "working", "tool": return "trabalhando"
        case "asking":          return "perguntando"
        case "waiting":         return "esperando"
        case "done":            return "concluido"
        case "error":           return "erro"
        default:                return "ocioso"
        }
    }
}

struct Limite: Decodable, Identifiable {
    let l: String       // rótulo
    let p: Int          // percentual
    let r: String       // quando reseta
    let s: String       // severidade
    let a: Bool         // é o que está valendo agora

    var id: String { l }
}

/// Consumo numa janela (5h ou 7 dias), calculado dos transcripts locais.
struct Faixa: Decodable {
    let saida: Int
    let reqs: Int
    let pico: Int
    /// Percentual do SEU pico no período — nunca do limite da Anthropic,
    /// cujo denominador não é público. -1 = histórico curto demais pra comparar.
    let pct: Int
    var comparavel: Bool { pct >= 0 }
}

struct Janelas: Decodable {
    let ok: Bool
    let sessao: Faixa?
    let semana: Faixa?
    let historico_d: Double?
}

struct Uso: Decodable {
    let requests: Int?
    let input: Int?
    let output: Int?
    let cache_read: Int?
}

struct AppEstado: Decodable {
    let uptime_s: Int
    let eventos: Int
    let placa_ip: String
    let placa_age_s: Int       // -1 = a placa nunca apareceu
    let sessoes: [Sessao]
    let limites: [Limite]
    let limites_age_s: Int     // -1 = indisponível
    let pico: Int              // -1 = indisponível
    let uso: Uso
    /// true = o bridge responde a qualquer um na rede local. Existe só para
    /// placas gravadas antes do token; some quando a placa é regravada.
    let rede_aberta: Bool?
    let janelas: Janelas?

    /// A placa só conta como conectada se falou com o bridge há pouco.
    /// Ela consulta a cada 600ms; 10s de silêncio já é ausência.
    var placaViva: Bool { placa_age_s >= 0 && placa_age_s <= 10 }

    /// O cache de limites deveria ter no máximo 5 min (o TTL do próprio
    /// Claude Code). Acima disso o número na tela é ficção e precisa
    /// aparecer com a idade ao lado.
    var limitesConfiaveis: Bool { limites_age_s >= 0 && limites_age_s < 300 }
}

/// Formata número grande sem poluir: 251502 -> "251K", 3378109531 -> "3.4B".
func compacto(_ n: Int?) -> String {
    guard let n = n else { return "—" }
    let d = Double(n)
    switch d {
    case 1e9...:  return String(format: "%.1fB", d / 1e9)
    case 1e6...:  return String(format: "%.1fM", d / 1e6)
    case 1e3...:  return String(format: "%.0fK", d / 1e3)
    default:      return "\(n)"
    }
}

/// "3d", "2h", "14min", "agora" — mesma escala curta usada na placa.
func idadeCurta(_ segundos: Int) -> String {
    switch segundos {
    case ..<60:      return "agora"
    case ..<3600:    return "\(segundos / 60)min"
    case ..<86400:   return "\(segundos / 3600)h"
    default:         return "\(segundos / 86400)d"
    }
}
