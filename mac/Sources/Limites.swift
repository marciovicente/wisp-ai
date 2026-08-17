import Foundation

/// Busca os limites reais da assinatura, direto da Anthropic.
///
/// POR QUE ISTO EXISTE
/// -------------------
/// O Claude Code guarda os percentuais num cache em ~/.claude.json com prazo
/// de 5 minutos. Só que o cache não se renova sozinho: ele é reescrito quando
/// uma resposta da API traz os cabeçalhos de limite. Se você passa dias sem
/// abrir o painel de uso, o número em disco fica parado — medido, três dias.
///
/// Aqui a gente faz a mesma chamada que o Claude Code faz. O endpoint saiu da
/// leitura do próprio binário:
///
///     fetchUtilization: GET /api/oauth/usage
///
/// SOBRE A CREDENCIAL
/// ------------------
/// O token de acesso é do Claude Code, guardado no chaveiro do macOS. Este app
/// pede ao sistema, e é o **macOS** que decide — mostrando um diálogo pra
/// você autorizar na primeira vez. Sem sua autorização explícita, não há
/// leitura: o app cai de volta no cache em disco e avisa a idade dele.
///
/// O token nunca sai da sua máquina. Ele vai num cabeçalho para
/// api.anthropic.com e em nenhum outro lugar. O bridge nem chega a vê-lo — o
/// que trafega para ele é só o resultado, por 127.0.0.1.
enum Limites {

    /// Item de chaveiro que o Claude Code cria ao autenticar.
    private static let servico = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum Falha: Error, Equatable {
        case semCredencial(OSStatus)   // inclui o caso "você recusou"
        case semToken
        case http(Int)
        case rede(String)

        var descricao: String {
            switch self {
            case .semCredencial(let s) where s == errSecUserCanceled:
                return "acesso ao chaveiro recusado"
            case .semCredencial(let s) where s == errSecItemNotFound:
                return "credencial do Claude Code não encontrada"
            case .semCredencial(let s):
                // O número importa: sem ele, "não deu" é indepurável.
                return "chaveiro recusou (status \(s))"
            case .semToken:
                return "credencial sem token de acesso"
            case .http(401), .http(403):
                return "credencial expirada — abra o Claude Code"
            case .http(let c):
                return "a Anthropic respondeu \(c)"
            case .rede(let m):
                return m
            }
        }
    }

    // MARK: - chaveiro

    private nonisolated static func token() throws -> String {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(consulta as CFDictionary, &item)
        guard status == errSecSuccess, let dados = item as? Data else {
            throw Falha.semCredencial(status)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: dados),
              let t = procurar(raw, chave: "accessToken") else {
            throw Falha.semToken
        }
        return t
    }

    /// O formato da credencial não é documentado e já mudou de nível de
    /// aninhamento entre versões. Procurar pela chave em qualquer
    /// profundidade custa nada e sobrevive a reorganização.
    private static func procurar(_ no: Any, chave: String) -> String? {
        if let d = no as? [String: Any] {
            for (k, v) in d {
                if k.caseInsensitiveCompare(chave) == .orderedSame,
                   let s = v as? String, !s.isEmpty { return s }
                if let achado = procurar(v, chave: chave) { return achado }
            }
        }
        if let a = no as? [Any] {
            for v in a { if let achado = procurar(v, chave: chave) { return achado } }
        }
        return nil
    }

    // MARK: - busca

    /// Devolve o objeto de utilização cru, do jeito que a Anthropic mandou.
    /// Quem interpreta é o bridge, que já sabe o formato por causa do cache.
    static func buscar() async throws -> [String: Any] {
        // FORA da main actor, obrigatoriamente.
        //
        // SecItemCopyMatching é síncrona e, quando o macOS resolve pedir sua
        // autorização, ela só retorna depois que você responde ao diálogo.
        // Chamada da main actor, isso congela a interface inteira enquanto a
        // janela espera — e o painel fica travado justamente no momento em
        // que precisa explicar o que está acontecendo.
        let t = try await Task.detached(priority: .userInitiated) {
            try token()
        }.value

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let dados: Data, resp: URLResponse
        do {
            (dados, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Falha.rede(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else { throw Falha.rede("resposta inválida") }
        guard http.statusCode == 200 else { throw Falha.http(http.statusCode) }

        guard let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
            throw Falha.rede("resposta não é JSON")
        }
        return obj
    }

    /// Conta ao bridge por que não deu, para o motivo aparecer em /app e não
    /// ficar preso dentro do app. Diagnosticar "está usando o cache" sem saber
    /// a causa é adivinhação.
    static func reportarFalha(_ motivo: String, porta: Int) async {
        await postar(["erro": motivo], porta: porta)
    }

    /// Entrega ao bridge, que passa a preferir isto ao cache em disco.
    static func entregar(_ utilizacao: [String: Any], porta: Int) async {
        await postar(utilizacao, porta: porta)
    }

    private static func postar(_ corpoObj: [String: Any], porta: Int) async {
        guard let corpo = try? JSONSerialization.data(withJSONObject: corpoObj) else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/limites")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = corpo
        _ = try? await URLSession.shared.data(for: req)
    }
}
