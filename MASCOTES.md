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

---

# Receita pronta: o Terminal

Um computador de mesa retrô, tela CRT âmbar como rosto, bracinhos, sem pernas
— ele *senta* na mesa. O âmbar amarra com o laranja da Fagulha, e é
historicamente correto para um monitor da época.

## Onde gerar

Qualquer modelo de imagem serve. O que decide o resultado é a **técnica**, não
a ferramenta:

| onde | por quê |
|---|---|
| **ChatGPT** ou **Gemini** | geram e depois EDITAM na mesma conversa. É o caminho mais fácil para manter o mesmo personagem, e provavelmente você já tem |
| **Midjourney** | melhor acabamento neste estilo 3D. Use `--cref <url-da-primeira-imagem>` em todas as outras |
| **Blender** | consistência perfeita e estados futuros de graça. Só se você topar a curva |

**A regra que decide tudo:** gere **um** personagem primeiro, aprove, e depois
peça as variações **na mesma conversa**, sempre dizendo "o mesmo personagem".
Recomeçar do zero a cada estado produz oito bonecos diferentes.

## Prompt base — gere este primeiro

> A small retro desktop computer character, 3D render, soft matte clay-like
> material. Chunky rounded cream-beige plastic body like a 1984 all-in-one
> home computer. Its face is a warm amber-glowing CRT screen. Two short stubby
> arms, no legs — it sits on a desk. Eyes are simple glowing amber pixel
> shapes on the screen. Cute, friendly, slightly chunky proportions, big head
> small body. Soft studio lighting from the upper left, gentle shadow. Full
> body, centered, facing the viewer, plain flat background. 3D icon style,
> high detail.

Gere até gostar. **Só siga adiante quando o personagem estiver aprovado** — é
ele que vai se repetir oito vezes.

## Os oito estados

Para cada um, escreva: *"O mesmo personagem, mesma câmera, mesma iluminação,
mesmo tamanho no quadro. Agora:"* seguido da linha abaixo.

| arquivo | peça isto |
|---|---|
| `idle.png` | relaxed and content, eyes half-closed, small pixel smile, arms resting at its sides, screen glowing softly |
| `working.png` | thinking — eyes looking up and to the side, one arm raised to its chin, faint scrolling text on the screen |
| `tool.png` | busy working, leaning forward, both arms out and typing, narrowed focused eyes, cascading code characters on the screen |
| `asking.png` | surprised and curious, wide round eyes, a large glowing question mark on the screen, one arm raised as if asking |
| `waiting.png` | anxious and pleading, wide worried eyes, both arms clasped together in front, hunched slightly forward |
| `done.png` | celebrating, both arms thrown up in the air, happy closed arc eyes and a wide smile on the screen, small sparks around it |
| `error.png` | worried and apologetic, inner eyebrows raised, wavy mouth, glitch and static lines across the screen, arms drooping |
| `offline.png` | powered off — screen completely dark with no glow, slumped posture, arms limp, dim and lifeless |

Repare que `error` é **preocupado, não bravo**: a culpa não é de quem olha. E
`tool` é o "trabalhando de verdade" — corpo inclinado e mãos ocupadas é o que
faz esse estado ser legível de longe.

## Depois de gerar

**1. Tire o fundo.** Modelos de imagem quase nunca entregam PNG transparente.
No macOS não precisa instalar nada: abra no Preview, `Ferramentas > Remover
Fundo`, e salve como PNG. Alternativas: remove.bg, Pixelmator.

**2. Nomeie e largue na pasta:**

```
~/.fagulha/mascotes/terminal/
  idle.png  working.png  tool.png  asking.png
  waiting.png  done.png  error.png  offline.png
```

**3. Escolha no painel do app.** O seletor "Personagem" aparece sozinho assim
que a pasta tiver os oito.

Não se preocupe em acertar tamanho e centralização na mão — veja
`mac/normalizar-mascote.sh` no repositório.
