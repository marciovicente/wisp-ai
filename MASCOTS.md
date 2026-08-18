# Making a mascot

Wisp ships with a character drawn as vectors, in code. This document is for
replacing it with real art — hand-drawn, commissioned or generated.

Drop the folder in `~/.wisp/mascots/<name>/` and pick it in the app's panel.

## What you need to deliver

**Eight PNGs**, one per state, with these exact names:

| file | when it shows | what the character feels |
|---|---|---|
| `idle.png` | nothing running | calm, present, at loose ends |
| `working.png` | Claude thinking | focused, looking up and to the side |
| `tool.png` | running a tool | actually working, hands busy |
| `asking.png` | asked you a question | surprised, eyebrows up, waiting |
| `waiting.png` | asking permission | anxious, almost pleading |
| `done.png` | finished | celebrating, without restraint |
| `error.png` | failed | **worried, not angry** — it is not your fault |
| `offline.png` | no connection | dark, asleep, lifeless |

## Technical spec

- **PNG with a transparent background.** No flat shadow baked into the
  background; if you want a shadow, make it part of the drawing and
  transparent at the edges.
- **Square**, 512×512 or 1024×1024. Bigger does not help: the largest use is
  236px.
- **Same framing across all eight.** This is the item that ruins this work
  most often: if the character is bigger in one file and further left in
  another, it *jumps* when the state changes, and the effect reads as a bug,
  not as animation.
- **10% margin all around**, so arms, tentacles and gestures that leave the
  body have room without touching the edge.
- **The character planted on the bottom of the frame.** The code makes it
  float and squash from there; if every file has a different floor, the motion
  comes out crooked.
- **Light always from the same side**, in all eight.

## How to generate them and keep the same character

Consistency is the whole job. Drawing a nice character is easy; drawing *the
same* character eight times is the work.

What works, easiest first:

1. **Generate one and ask for variations in the same conversation.** Image
   models with conversational editing (Gemini, ChatGPT) keep the character
   when you say "same character, now surprised". Do not start over for each
   state — the character drifts.
2. **Midjourney with `--cref`** (character reference). It was built for
   exactly this problem.
3. **Blender.** Model once, pose eight times, render. Perfect consistency, and
   new states come free afterwards. This is the path if you want to make three
   mascots.

Always ask for: transparent background, same camera distance, same lighting,
full body, character centered.

## Does it look good without animation?

It does. The images are static and the **motion comes from the code**: the
character breathes, squashes and stretches, floats and tilts its head. The
asking and waiting states sway; the error state sits crooked.

That is deliberate. The floating mascot is 46px, and on the board it lives
between 140 and 236px — frame-by-frame animation would be invisible work at
that size. Start with eight images; if it ever justifies itself, the loader
accepts sequences.

## If a state is missing

The whole set is ignored and the built-in vector comes back. A coherent
character beats seven pretty frames and a hole.

---

# A ready recipe: the Terminal

A retro desktop computer, amber CRT screen for a face, little arms, no legs —
it *sits* on the desk. The amber ties into Wisp's orange, and it is
historically correct for a monitor of that era.

## Where to generate it

Any image model will do. What decides the result is the **technique**, not the
tool:

| where | why |
|---|---|
| **ChatGPT** or **Gemini** | they generate and then EDIT in the same conversation. Easiest way to keep the same character, and you probably already have one |
| **Midjourney** | best finish in this 3D style. Use `--cref <url-of-the-first-image>` on all the others |
| **Blender** | perfect consistency and future states for free. Only if you are up for the learning curve |

**The rule that decides everything:** generate **one** character first, approve
it, and only then ask for the variations **in the same conversation**, always
saying "the same character". Starting over for each state produces eight
different characters.

## Base prompt — generate this one first

> A small retro desktop computer character, 3D render, soft matte clay-like
> material. Chunky rounded cream-beige plastic body like a 1984 all-in-one
> home computer. Its face is a warm amber-glowing CRT screen. Two short stubby
> arms, no legs — it sits on a desk. Eyes are simple glowing amber pixel
> shapes on the screen. Cute, friendly, slightly chunky proportions, big head
> small body. Soft studio lighting from the upper left, gentle shadow. Full
> body, centered, facing the viewer, plain flat background. 3D icon style,
> high detail.

Generate until you like it. **Only move on once the character is approved** —
this is the one that has to repeat itself eight times.

## The eight states

For each one, write: *"The same character, same camera, same lighting, same
size in frame. Now:"* followed by the line below.

| file | ask for this |
|---|---|
| `idle.png` | relaxed and content, eyes half-closed, small pixel smile, arms resting at its sides, screen glowing softly |
| `working.png` | thinking — eyes looking up and to the side, one arm raised to its chin, faint scrolling text on the screen |
| `tool.png` | busy working, leaning forward, both arms out and typing, narrowed focused eyes, cascading code characters on the screen |
| `asking.png` | surprised and curious, wide round eyes, a large glowing question mark on the screen, one arm raised as if asking |
| `waiting.png` | anxious and pleading, wide worried eyes, both arms clasped together in front, hunched slightly forward |
| `done.png` | celebrating, both arms thrown up in the air, happy closed arc eyes and a wide smile on the screen, small sparks around it |
| `error.png` | worried and apologetic, inner eyebrows raised, wavy mouth, glitch and static lines across the screen, arms drooping |
| `offline.png` | powered off — screen completely dark with no glow, slumped posture, arms limp, dim and lifeless |

Note that `error` is **worried, not angry**: it is not the viewer's fault. And
`tool` is the "actually working" one — a leaning body and busy hands are what
make that state readable from across the room.

## After generating

**1. Remove the background.** Image models almost never hand you a transparent
PNG. On macOS you need to install nothing: open it in Preview,
`Tools > Remove Background`, and save as PNG. Alternatives: remove.bg,
Pixelmator.

**2. Name them and drop them in the folder:**

```
~/.wisp/mascots/terminal/
  idle.png  working.png  tool.png  asking.png
  waiting.png  done.png  error.png  offline.png
```

**3. Pick it in the app's panel.** The "Character" selector appears on its own
once the folder has all eight.

Do not worry about getting size and centering right by hand — see
`mac/normalize-mascot.sh` in the repository.
