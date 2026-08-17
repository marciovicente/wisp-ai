import SwiftUI

/// Fagulha — o bridge do Waveshare, com cara.
///
/// O app existe por dois motivos práticos, nesta ordem:
///
///   1. Ele É o autostart. Antes disso, o bridge só rodava enquanto alguém o
///      tivesse subido num terminal; um reboot deixava a placa órfã e não
///      havia sinal nenhum de que isso tinha acontecido. Agora tem ícone.
///   2. O consumo fica legível sem depender da placa.
///
/// LSUIElement=true no Info.plist: sem ícone no Dock, sem janela. Só a barra.
/// Encerramento: sem isto o processo do bridge sobrevive ao app e é readotado
/// pelo PID 1 — medido, não suposto. Ele fica servindo pra sempre, e os três
/// `dns-sd` filhos junto, anunciando um bridge que você acha que fechou.
final class Delegado: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ nota: Notification) {
        MainActor.assumeIsolated { Bridge.compartilhado.parar() }
    }
}

@main
struct FagulhaApp: App {
    @NSApplicationDelegateAdaptor(Delegado.self) private var delegado
    @StateObject private var bridge = Bridge.compartilhado

    var body: some Scene {
        MenuBarExtra {
            Painel(bridge: bridge)
        } label: {
            // Ícone + o número que interessa. Chama pouca atenção quando está
            // tudo bem, e o percentual sobe junto com o aperto.
            HStack(spacing: 3) {
                Image(systemName: iconeBarra)
                Text(bridge.rotuloBarra)
            }
            .onAppear { bridge.iniciar() }
        }
        .menuBarExtraStyle(.window)
    }

    /// O ícone conta o estado antes de você abrir o painel.
    private var iconeBarra: String {
        guard bridge.estado.vivo else { return "bolt.slash" }
        guard let d = bridge.dados else { return "bolt" }
        if d.sessoes.contains(where: { $0.st == "asking" || $0.st == "waiting" }) {
            return "bolt.badge.checkmark"   // a bola está com você
        }
        if d.sessoes.contains(where: { $0.st == "working" || $0.st == "tool" }) {
            return "bolt.fill"             // Claude trabalhando
        }
        return "bolt"
    }
}
