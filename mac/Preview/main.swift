import SwiftUI
import AppKit

// Folha de contato do mascote: desenha os oito estados num PNG para você
// olhar lado a lado. Rode com ../preview.sh
//
// Serve para mexer no personagem sem precisar abrir o app: altere
// Sources/Mascote.swift, rode isto, olhe o resultado. O ciclo inteiro leva
// uns cinco segundos.

struct Folha: View {
    let linhas: [[EstadoMascote]] = [
        [.ocioso, .trabalhando, .ferramenta, .perguntando],
        [.esperando, .concluido, .erro, .offline],
    ]
    var body: some View {
        VStack(spacing: 14) {
            // Tamanho grande para julgar o desenho…
            ForEach(linhas.indices, id: \.self) { i in
                HStack(spacing: 16) {
                    ForEach(linhas[i], id: \.self) { e in
                        VStack(spacing: 4) {
                            Mascote(estado: e, lado: 76)
                            Text(e.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
            // …e pequeno, que é como ele aparece na lista de sessões. Um
            // personagem que só funciona grande não serve: aqui ele vive a
            // 20px na maior parte do tempo.
            HStack(spacing: 10) {
                ForEach(EstadoMascote.allCases, id: \.self) { e in
                    Mascote(estado: e, lado: 22)
                }
            }
            .padding(.top, 2)
        }
        .padding(20)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }
}

@MainActor
func gerar(_ destino: String) {
    let r = ImageRenderer(content: Folha())
    r.scale = 2
    guard let img = r.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("falhou ao renderizar")
        exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: destino))
    print(destino)
}

MainActor.assumeIsolated { gerar(CommandLine.arguments[1]) }
