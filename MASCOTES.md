# Fazendo um mascote

O Fagulha vem com um personagem desenhado em vetor, no código. Este documento
é para trocá-lo por arte de verdade — feita à mão, encomendada ou gerada.

Largue a pasta em `~/.fagulha/mascotes/<nome>/` e escolha no painel do app.

## O que você precisa entregar

**Oito PNGs**, um por estado, com estes nomes exatos:

| arquivo | quando aparece | o que o personagem sente |
|---|---|---|
| `idle.png` | nada rodando | calmo, presente, à toa |
| `working.png` | Claude pensando | concentrado, olhando para o lado/cima |
| `tool.png` | rodando ferramenta | trabalhando de verdade, mãos ocupadas |
| `asking.png` | te fez uma pergunta | surpreso, sobrancelhas erguidas, esperando |
| `waiting.png` | pedindo permissão | ansioso, quase implorando |
| `done.png` | concluiu | comemorando, sem moderação |
| `error.png` | falhou | **preocupado, não bravo** — a culpa não é sua |
| `offline.png` | sem conexão | apagado, adormecido, sem vida |

## Especificação técnica

- **PNG com fundo transparente.** Sem sombra chapada no fundo; se quiser
  sombra, que ela seja parte do desenho e transparente nas bordas.
- **Quadrado**, 512×512 ou 1024×1024. Maior não ajuda: o maior uso é 236px.
- **Mesmo enquadramento nos oito.** Este é o item que mais estraga esse
  trabalho: se o boneco estiver maior num arquivo e mais à esquerda em outro,
  ele *pula* ao trocar de estado, e o efeito é de falha, não de animação.
- **Margem de 10% em volta**, para braços, tentáculos e gestos que saem do
  corpo caberem sem encostar na borda.
- **O personagem apoiado na base do quadro.** O código faz ele flutuar e
  comprimir a partir dali; se cada arquivo tiver um chão diferente, o
  movimento fica torto.
- **Luz sempre do mesmo lado**, nos oito.

## Como gerar mantendo o mesmo personagem

Consistência é o trabalho todo. Desenhar um boneco bonito é fácil; desenhar
*o mesmo* boneco oito vezes é o que dá trabalho.

O que funciona, em ordem de facilidade:

1. **Gere um só e vá pedindo variações na mesma conversa.** Modelos de imagem
   com edição conversacional (Gemini, ChatGPT) mantêm o personagem quando
   você diz "o mesmo personagem, agora surpreso". Não recomece do zero a cada
   estado — o boneco muda.
2. **Midjourney com `--cref`** (referência de personagem). Foi feito
   exatamente para esse problema.
3. **Blender.** Modela uma vez, posa oito vezes, renderiza. Consistência
   perfeita, e depois novos estados saem de graça. É o caminho se você quiser
   fazer três mascotes.

Peça sempre: fundo transparente, mesma distância de câmera, mesma iluminação,
corpo inteiro, personagem centralizado.

## Fica bom sem animação?

Fica. As imagens são estáticas e o **movimento vem do código**: o boneco
respira, comprime e estica, flutua e inclina a cabeça. Os estados de pergunta
e espera balançam; o de erro fica torto.

Isso é de propósito. O mascote flutuante tem 46px e na placa vive entre 140 e
236px — animação quadro a quadro seria trabalho invisível nesse tamanho.
Comece com oito imagens; se um dia justificar, o carregador aceita sequências.

## Se faltar algum estado

O conjunto inteiro é ignorado e volta o vetor embutido. É melhor um
personagem coerente do que sete quadros bonitos e um buraco.
