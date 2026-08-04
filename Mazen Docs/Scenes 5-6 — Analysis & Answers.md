# Scenes 5 & 6 — Analysis, Answers, Build Order

**Status: Scene 5 items 1–5 BUILT (2026-08-03) — diagnostic pulse, three receiver states, basin +
bowls (material 35), seamless live circuit, and the 5J bloom (channels flood, the tile grid
surfaces on the pale stone, then settles to a resting glow). Deferred as planned: 5K's staged
emergence, 5H's near-miss aids. Scene 6 critical path BUILT same day: 6D latches + hatch,
route naming (`WorldCatalog.routeName`), 6E/6F second descent onto `-Z`, 6G arrival
acknowledgement, 6H metal vessel, 6I/6J three-fact route-keyed portal. Deferred: 6J's portal
image, 6K, the 6A afterimage, and the sky decision (Eddie's).**

*Written 2026-08-03, against the scripts in `Scenes/` (read-only) and the code as it stands.
Analysis only — recommendations, not work done. Companion to the
[Prologue Build Plan](Prologue%20Build%20Plan%20—%20Scenes%201-4.md).*

---

## Scene 5 — "The Broken Meridian"

### What the script asks vs what stands

| beat | script | built | verdict |
|---|---|---|---|
| 5A world | pale stone, channels, twist enabled | ✅ (+ six rotators, an addition) | done |
| 5B broken channels | grooves that stop at misaligned seams | ✅ both-ends rule | done |
| 5C source | **basin in three nested mineral rings**; player-triggered **diagnostic pulse** | ❌ a layered vessel; no diagnostic | **gap** |
| 5C pulse | travels at walking speed, fails visibly, withdraws, repeats | ✅ real simulated front | done |
| 5D receivers | **crescent/bowl embedded in a junction**; three distinct states | ❌ scaled obelisks; lit/unlit only | **gap** |
| 5E first turn "plainly correct" | one obvious fix on arrival | ✅ by construction — the scramble search required it | done |
| 5F junction vessels | mirror local truth | ✅ at face-edge crossings | done |
| 5G decoys | a turn that makes things worse must exist | ✅ a search criterion | done |
| 5H third receiver on another face | forces cross-face planning | ✅ structurally (runs cross edges by length) | verify in play |
| 5H readability aids | manual pulse; near-miss glow; approach shimmer | ❌ none of the three | gap |
| 5I completion | pulse stops withdrawing, becomes continuous, basin fills | ⚠️ cycles with a 0.8 s hold — not seamless | small gap |
| 5J world-becomes-a-diagram | whole circuit blooms, grid revealed, music enters | ❌ | **the big one** |
| 5K exit | far end of the current, `.goto` to Scene 6 | ✅ | done |
| 5K activation | 5-step emergence (light square → current from three sides → frame rises) | ❌ portal appears instantly | gap |

### Answers to the script's open questions

- **"Dormant arch throughout, or rises after completion — either is valid."** → **Rises after.**
  Already built that way, and it is the right call: on a twisting world a dormant arch telegraphs
  the answer's location all scene, and the 5K emergence sequence only makes sense for a thing that
  arrives.
- **How are turns made?** The script says "the player moves onto the relevant outer slice and
  initiates a player-controlled twist… the player rides the slice." The six rotators satisfy this
  *more* literally than Q/E: the control stands ON the slab it turns, so pressing it is riding it.
  Keep both inputs; the rotators are canon now.
- **"The exact sequence can be authored for engine constraints."** The scramble-by-search approach
  is compatible with the script by its own words. Keep; re-run the search if the channel layout
  ever changes.

### Recommended improvements, in order

1. **The diagnostic pulse (5C)** — smallest, highest leverage. `interact()` at the source fires a
   brighter front immediately (reuse `pulseFront`, add a `bright` flag the shader scales). It also
   answers the pacing worry: a 10-step route means ~12 s per natural cycle, and impatience is
   solved by the script's own mechanism, not by speeding the pulse up.
2. **Locked vs temporarily-fed receivers (5D's three states).** The model already knows the
   difference (`fed` vs `liveCircuit`); it just isn't shown. Locked → steady emitter tone + full
   glow; temporarily fed → the existing brief tone + glow that decays when the pulse withdraws.
   "Temporary success is deliberately different from lasting success" is a scene pillar and
   currently invisible.
3. **Basin source + bowl receivers.** Two new lathe profiles (the machinery exists — vessel and
   obelisk are both lathes). The source-as-vessel actively muddies 5F: the scene argues vessels
   *observe* the circuit, and the source *is* the circuit. Do the receivers first; their shape
   ("crescent/bowl") also fixes the last trace of the needle look.
4. **5I seamless circuit.** When `liveCircuit`, drop the hold: the front passes each receiver
   without withdrawing and re-enters at the source. ~10 lines in `tickChannelPulse`.
5. **5J, the bloom.** One uniform (`worldBloom`, 0→1 over ~6 s on completion) read by materials 33
   (all circuit channels to full), 34 (brighten the pale-stone slab lines so the grid surfaces),
   and the receiver/vessel glow. Audio: the three receiver tones + source align (all registered
   already) and the first full music bed. This is the scene's payoff and mostly shader dials —
   medium effort, no new systems.
6. **5K emergence staging** — the 5-step sequence as a timed prop animation (`alignAnim` on the
   portal frame, the channel material already knows how to run current toward a tile). Polish;
   after the above.
7. **5H near-miss aids** (channels glow along almost-connected routes; the shimmer within one
   junction) — nice, defer; the diagnostic pulse covers most of the need.

---

## Scene 6 — "The World Remembered"

### What stands

Arrival from Scene 5 lands on `-X` (route-keyed spawn), persistence is proven and tested at the
registry level, the region is dressed as machinery (decks, pillars, cables — Eddie-approved), and
the hub door resolves to the Scene 2 instance with origin `scene-5`. **The region is still a dead
end by design** — 6D is the thing that opens it.

### The gaps, in dependency order

1. **6D — the three under-platform latches.** The critical path: nothing else in the scene is
   reachable until this exists. Three latch props on `-X` near the assembly edge, activated in
   physical order along the structure; out-of-order presses rebuff (the obelisk-refusal pattern,
   already built). The third opens a route through the seam to `+Z` — which under the new edge
   model is just opening both halves of authored walls, no special casing. Each latch answers with
   light/sound *up into the assembly overhead* (segment lights exist).
2. **6E/6F — the second descent.** A portal on `-X` into Scene 3's interior, entering at a face
   the first visit never used: `arrivalSpawns["scene-2"]` on Scene 3 (the machinery exists and is
   tested). The interior arrives still solved — already guaranteed and tested. Script offers four
   forms for the entrance; recommend **the narrow shaft through the rotated slice** — it is the
   only one that *reads as a consequence of the twist*, which is the scene's thesis.
3. **6G — approach as input.** On arrival from the new edge: nearest beam brightens, orb turns a
   facet, old nebula frame flickers, beams desynchronise briefly. All drivable from
   `lastArrivalOrigin` + `chamberEmitters`; no new rendering tech.
4. **6H — the metal vessel.** Cheapest high-value item: the existing vessel lathe with the
   chamber's metal materials (25/32 palette), rings answering a beat after each beam pulse.
5. **6I/6J — the route-keyed portal.** Script recommends Option C; **agree**. All three conditions
   are already queryable: Scene 2 still twisted (the chamber portal sits on `+Z`), Scene 3 solved
   (`sceneThreeAllObelisksAwake`), arrival via Scene 5 (`lastArrivalOrigin`). The one missing
   piece is small: a cross-world query helper on `WorldRegistry` so one world can ask about
   another by name. Portal image: defer the layered-vistas field; ship the audio chord instead —
   all four remembered tones (Scene 2's incomplete, 3's harmonic, 4's strain, 5's current) are
   registered and just need playing together.
6. **6A/6B recognition polish** — the arrival portal's afterimage ("a pale circuit-like afterimage
   across the old stone, then fades into mineral stains" — the channel material can draw exactly
   this), and the sky question below.
7. **6K** — the sweeping view; camera beat, judge it last.

### The one real design decision Eddie should make

**The sky.** Script 6A: "the small dark Scene 4 world remains visible overhead." But Scene 6 *is*
the Scene 2 instance, and Scene 2's stamp declares no sky counterpart (default = moon). Options:

- **(a) Give Scene 2 the Scene 4 sky permanently** — wrong: on the first visit Scene 4 hasn't
  happened yet, and hanging it overhead spoils it.
- **(b) Set the counterpart on arrival when `lastArrivalOrigin == "scene-5"`** — the sky becomes
  route-keyed, exactly like the spawn. **Recommended:** it is one line in the swap, it is
  data-driven, and "what hangs in your sky is an edge, not a fact" is already the registry's
  stated philosophy.
- (c) Ignore the script line — defensible, but the overhead reference is one of 6B's strongest
  recognition cues.

### Suggested build order (Scene 6 first — it is the blocker)

6D → 6E/6F → 6G+6H together → 6I/6J → then Scene 5's items 1–4 as the polish pass → 5J and 6K as
the two finale beats, built last so both payoffs are judged against finished scenes.
