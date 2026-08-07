# Audio Plan — PHASE

*How and where to use Apple's Physical Audio Spatialization Engine in Garden of Worlds. Written
against the six-scene prologue scripts and the engine as it stands. Nothing integrated yet.*

---

## 1. Why this matters more than "adding sound"

Read the scripts' audio beats together and a pattern jumps out. Almost none of them are ambience —
they are **information about things the player cannot see**:

> "A low tone sounds from **elsewhere on the world**."
> "A deep mechanical latch sounds **somewhere beyond the visible maze**."
> "The tone repeats **from the direction of** the matching obelisk."
> "A distant answering tone sounds **from somewhere else in the maze**."
> "Something deep within **the far side of the world** answers with a muted vibration."

The prologue has a hard rule — **no interface overlays**. Every script says objectives are never
displayed. So the game's entire "where do I look now?" channel is *diegetic*, and most of it is
sound. That makes spatial audio **load-bearing**, not polish.

It also answers the problem you hit in Scene 2 directly: *"I was looking the wrong way when things
rotated."* Your own script already solves it — the ground tone, the dust, the deep latch — but those
cues only work if they arrive **from the right direction**. A stereo blip cannot do that; a
positioned emitter can.

**Conclusion:** PHASE isn't a late polish pass. It should land before Scenes 3 and 5, whose puzzles
(match a remote obelisk by its answering tone; follow a pulse around a world) are *unsolvable as
designed* without directional sound.

---

## 2. What this engine makes unusual

Four constraints fall out of the cube topology. They're the reason a generic "play a sound at a
position" wrapper would be wrong.

### 2.1 Emitters ride facelets — the twist-safety rule applies to audio
Props live on facelets, and a twist **moves them**. A humming obelisk on a turning slab must have its
emitter travel with it, mid-turn, or the sound will detach from the object. This is exactly the rule
already governing dressed walls: **derive from live topology every frame, never cache a world
position**. Any audio emitter bound to a prop must be re-resolved from `(cubie, facelet)`, not stored
as a coordinate.

### 2.2 The listener's "up" rotates — twice over
- Crossing a face boundary rotates the player's orientation (`+Z` becomes a wall behind you).
- Riding a twisting slab rotates them again, mid-motion.

PHASE's listener takes a full transform, so this is expressible — but it must be driven from the
same source as the camera, or sound and image will disagree during exactly the moments that matter.

### 2.3 Worlds are swapped and persistent
Each `GameState` is its own place, and portals swap which is current. Audio should follow: **one
PHASE scene graph, but sources owned per-world**, torn down and rebuilt on a world switch. The
counterpart world hanging in the sky must be **silent** — it's scenery, not a place you're in.

### 2.4 Interiors have no horizon
Scene 3's chamber puts all six faces in earshot at once, with maze walls between. Occlusion carries
much more information there than on an exterior world, because *everything* is nominally in range.

---

## 3. Architecture

### 3.1 Shape
```
AudioEngine (one, app-lifetime)
├── PHASEEngine + listener  ← driven from CameraState each frame
├── SoundBank               ← events registered once at boot
└── WorldAudio (per GameState, created/destroyed on world switch)
    ├── prop emitters       ← resolved from live topology, twist-safe
    ├── ambience bed        ← non-positional, per world
    └── one-shot pool       ← fire-and-forget events
```

Mirror the existing world-ownership model exactly: `GameState` owns its audio the way it owns its
skybox and celestial system. Nothing global except the engine and the sound bank.

### 3.2 Where it hooks in
The engine already has the events; none of them currently make a sound:

| Existing engine event | Sound it wants |
|---|---|
| `startSliceRotation` refused (`isRefusal`) | metallic tension building, then release — the strain |
| twist finalized | the deep locking sound |
| switch cap toggled | the short tone / the same tone reversed on disengage |
| bond dissolved | the settling sound "from elsewhere on the world" |
| sealed portal opens | the low stable tone |
| `beginObeliskAwakening` | the climbing tone, positioned at that obelisk |
| portal swap | descending tone folding inward; new world's bed fading up |
| player crosses a face boundary | the harmonic shift Scene 3 asks for |

That's eight hooks, all at points that already exist. **No new game logic is needed to start** — this
is why it's cheap to begin.

### 3.3 Occlusion: use the maze, not the mesh
PHASE can do geometry-aware occlusion, but feeding it the world mesh would be expensive and is
unnecessary here: **we already have the maze topology.** A line-of-sight test that walks the
`openings` grid between listener tile and source tile is cheap, exact, and twist-correct for free.
Use it to drive an occlusion parameter rather than handing PHASE geometry.

This is the single biggest win available — "the tone is muffled through two walls, clear down that
corridor" is precisely the navigation information the scripts are asking sound to carry.

---

## 4. Where the sounds come from

There are **no audio assets in the project**, and this is the real dependency — the equivalent of the
skybox problem.

**Recommendation: synthesise most of them.** Look at what the scripts actually ask for — *"a clear
tone", "a low incomplete tone", "the tone plays in reverse", "a deeper tone", "synchronized tones",
"a slightly different tone per beam"*. These are **pure tones and simple timbres**, not foley. They
can be generated as buffers at boot (sine/FM partials with envelopes) and registered as PHASE assets.

Three reasons this is the right call here:
- **It fits the fiction.** The Builders speak in geometry; tonal, synthetic, related-by-interval
  sounds *are* their grammar. A library of stock "sci-fi hum" would fight that.
- **It makes relationships authorable.** Scene 3 needs six obelisks whose tones are distinguishable
  but obviously kin — that's a harmonic series, trivially generated, painful to source.
- **No asset pipeline, no licensing.** Given the Shadertoy licensing detour, worth having.

Keep **recorded/CC0 assets** for the handful of textural things synthesis is bad at: wind, footsteps
on stone, dust and rubble, the "deep mechanical latch". Freesound CC0 or similar.

---

## 5. Phasing

**Phase A — Foundation (small).** PHASE engine boots, listener follows the camera, one non-positional
test tone on a keypress. Proves the framework and the listener transform. Verify the listener stays
correct across a face crossing and a twist — that's the part unique to this engine.

**Phase B — Twist voice (small, high value).** The refusal strain, the locking sound, switch tones.
All exist as engine events; all are what the prologue leans on hardest. This alone fixes "I was
facing the wrong way" for Scene 2.

**Phase C — Positional prop emitters (medium).** Emitters resolved from live topology every frame so
they ride twists. Looping sources for awakened obelisks. This is where the twist-safety rule gets
enforced — worth a test that an emitter's position tracks its facelet through a rotation.

**Phase D — Occlusion via maze topology (medium).** The line-of-sight walk. Unlocks the "seek the
answering tone" navigation that Scene 3 requires.

**Phase E — Beds and transitions (small).** Per-world ambience, the portal's descending fold, silence
on arrival then wind returning (Scene 2's script is precise about this).

**Phase F — Scene-specific (as needed).** Scene 3's six kin tones and the orb's response; Scene 5's
travelling pulse, whose sound must move along the channel with the light.

I'd do **A + B before Scene 4**, since Scene 4 is all about the twist and its refusal, and C + D
before Scene 3.

---

## 6. Risks and open questions

- **PHASE's event model is authoring-heavy.** It expects sound events assembled from assets and
  mixers. With synthesised buffers this is fine, but it is more ceremony than "play this file" — Phase
  A should confirm the ergonomics before committing.
- **Listener orientation during a twist** is the likeliest source of subtle wrongness; it's the one
  case where the player's own frame rotates under them.
- **Does the counterpart world make sound?** I've assumed silent. If a world overhead should be
  audible (an interesting idea — hearing a place you changed), that's a deliberate choice.
- **No save system**, so nothing to persist yet. Audio state is per-session.
- **Simulator/headless**: the test harness has no audio; keep all audio behind a protocol so the
  headless build and tests link without it.

---

## The thrum (2026-08-06) — three faults in one layer

Eddie, demoing to someone: *"What is the thrum sound I hear everywhere… it was driving the person I
was showing off the prototype to bonkers."* Flat regardless of position or world, an ~8 second
cycle, half a second of quiet, then again.

It was `ambience.undertone`: a 49 Hz looping tone, 8 seconds long. Every detail of the description
matched a line of code.

1. **The envelope.** `registerTone` applied `sustain`'s release ramp — the last 18% (1.4 s) fading to
   silence — and then the loop restarted at the 12 ms attack. An envelope shapes a sound that ENDS;
   on a loop it becomes a pulse, forever. Looping tones now get no envelope at all (the harmonics are
   integer multiples, so the seam is phase-continuous) plus a crossfade for safety.
2. **The scope.** Enabled by `outdoors && hasMoved`, with no scene in the condition — so Scene 1's
   introduce-the-Builders layer played in the garden, the natural world, the galleries and all six
   scenes, permanently. Now gated to `scene-1`, which is whose script it is.
3. **The level.** Registered at relative SPL 0 — the level of a CUE, something you are meant to
   notice — while its own comment says "almost below conscious notice". The bed runs at −12. It is
   now −20.

Any one of these alone would have been survivable. Together they made a 49 Hz pulse the loudest
continuous thing in the game.

**Also added: `;` mutes everything.** There was no way to silence the game short of muting the app in
System Settings, which is a thing to discover mid-demo with an audience.

**Lesson worth keeping:** the parameters that describe a one-shot (attack, sustain, decay) are
actively wrong for a loop, and nothing in the type system says so. `registerTone(… sustain: true,
looping: true)` compiled, sounded fine in isolation for eight seconds, and only revealed itself on
the ninth.
