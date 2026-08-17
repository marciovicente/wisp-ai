# Fagulha

Um mascote que mostra o que o Claude Code está fazendo — na barra de menu do
Mac, e opcionalmente numa telinha AMOLED em cima da sua mesa.

Cada sessão ativa do Claude vira um bonequinho com estado próprio: trabalhando,
rodando ferramenta, esperando sua permissão, te fazendo uma pergunta, concluído,
com erro. Quando não há nada rodando, a tela vira relógio e previsão do tempo —
boneco parado não informa nada.

Na barra de menu você vê consumo, limites e as sessões abertas sem sair do que
está fazendo.

## Instalação

```bash
git clone https://github.com/USUARIO/fagulha.git
cd fagulha
./install.sh
```

Precisa de macOS 14+, das ferramentas de linha de comando da Apple
(`xcode-select --install`) e de mais nada.

**Por que compilar em vez de baixar um app pronto:** app baixado da internet
recebe a marca de quarentena do macOS e, sem assinatura de desenvolvedor paga,
o sistema recusa abrir com um aviso de malware. App compilado na sua máquina
nunca recebe essa marca. Compilar aqui é o que *remove* a fricção, não o
contrário — e de quebra você lê o que está rodando.

## O que ele faz na sua máquina

Transparência importa aqui, porque o app lê dados do seu Claude Code:

| o quê | onde | por quê |
|---|---|---|
| lê os transcripts | `~/.claude/projects/**/*.jsonl` | contar requests e tokens |
| lê o cache de limites | `~/.claude.json` | os percentuais da assinatura |
| acrescenta hooks | `~/.claude/settings.json` | saber o que o Claude está fazendo |
| grava configuração | `~/.fagulha/config.json` | token, porta, cidade |
| sobe um servidor local | `127.0.0.1:4666` | a placa busca o estado aqui |

Os hooks são acrescentados aos seus, nunca por cima, e o arquivo é copiado
antes. `bridge/install_hook.py --dry-run` mostra o que mudaria; `--remove`
desfaz.

**Nada sai da sua máquina.** Não há telemetria, nem servidor nosso. As únicas
conexões externas são a previsão do tempo (Open-Meteo, sem cadastro) e, uma vez
só na instalação, a descoberta da sua cidade pelo IP.

### Sobre a rede

O bridge escuta na rede local porque a placa precisa alcançá-lo. Por isso ele
exige um **token** de quem vem de fora — gerado sozinho na instalação e gravado
na placa junto com o WiFi. Sem ele, qualquer pessoa na mesma rede leria seus
nomes de projeto e seu consumo.

Se você tiver uma placa gravada antes disso, `exigir_token: false` no config
mantém ela funcionando, e o app mostra um aviso amarelo até você regravar.

## Os limites da assinatura

O app busca os percentuais **direto da Anthropic**, no mesmo endpoint que o
Claude Code usa (`GET /api/oauth/usage`), a cada 5 minutos. São os mesmos
números que aparecem no painel de uso do Claude Code, sem depender de você
abri-lo.

Para isso ele precisa da credencial do Claude Code, que fica no chaveiro do
macOS. **Quem decide é o macOS**: na primeira vez aparece um diálogo pedindo
sua autorização. O token nunca sai da sua máquina — vai num cabeçalho para
`api.anthropic.com` e para lugar nenhum além disso, e o bridge sequer chega a
vê-lo.

Recusando, nada quebra: a opção se desliga sozinha (não insistimos), e o app
volta a ler o cache que o Claude Code mantém em `~/.claude.json`. Esse cache
tem prazo de 5 minutos, mas **só é reescrito quando algo dispara uma busca** —
numa máquina de teste ele ficou três dias parado porque ninguém abriu o painel
de uso. Quando é ele a fonte, o app mostra a idade ao lado do número e o
esmaece, em vez de apresentar dado antigo como se fosse atual.

Você pode desligar a busca a qualquer momento em **Buscar limites reais**, no
painel.

### Consumo calculado aqui

Independente de tudo isso, o app calcula dos seus transcripts o consumo nas
mesmas janelas (5h e 7 dias) e compara com o seu próprio pico dos últimos 30
dias. Esse número não depende de credencial, de rede nem de cache: é sempre
atual. Ele responde "hoje está fora do meu normal?", que é uma pergunta
diferente — e às vezes mais útil — que "quanto falta para o teto?".

## A placa (opcional)

O app funciona sozinho. A telinha é o extra.

Hardware: **Waveshare ESP32-S3-Touch-AMOLED-2.16** (480×480, touch, acelerômetro).
Deslizando para o lado aparece o painel de consumo; virando o aparelho a imagem
gira junto.

Gravar exige ESP-IDF 5.5. Veja [firmware/README.md](firmware/README.md).

## Desinstalar

```bash
/usr/bin/python3 bridge/install_hook.py --remove   # tira os hooks
rm -rf ~/Applications/Fagulha.app ~/.fagulha
```

## Licença

MIT.
