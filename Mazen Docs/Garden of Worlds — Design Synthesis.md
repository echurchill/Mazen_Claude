# The Garden of Worlds — Design Synthesis (North Star)

*Merges Eddie's [Garden of Worlds concept](The_Garden_of_Worlds_Game_Concept.md) + [inspirations](The_Garden_of_Worlds_Game_Inspirations.md) with the [Goal Ideas whiteboard](Goal%20Ideas%20Whiteboard.md) and everything we've built (M8–M13). Drafted 2026-07-07 from the design conversation. This is the star everything else points at — not a spec.*

## One line

> **A cozy, first-person archaeology of impossible worlds: you're a tiny traveler *inside* a cluster of maze-planets — learn how the world thinks, undo the ancient locks that hold it rigid, twist it open, and step inside to find the engineered truth beneath the natural surface.**

## The core insight (why this works)

Our two threads turned out to be one. The Garden concept is a beautiful *mind* — a "knowledge game" where understanding is the resource and the portal network is a language — but it was missing its **hands** (the minute-to-minute verb). Everything we've *built* — the slice-twist, bandaging, portals, "bigger on the inside," the world hanging in the sky — is exactly those hands. Eddie's **"bandage-locks are the things you break to get inside"** is the bolt that fastens them together, into a single loop where **the mechanic *is* the theme *is* the progression:**

> **Learn** (Witness-style, from the world itself) → which lets you **undo an ancient lock** (bandaging) → which lets you **twist the world open** (the slice) → to **step inside** a structure or planet (inverted-cube interiors / the world in the sky) → revealing the **engineered truth beneath the natural surface** → which teaches you the next thing.

No grind (every action reveals something new). No hand-holding (understanding leads, not quest markers). One deep verb, taken far.

## Design pillars

1. **Cozy, no-grind.** No timers, no punitive loss. "Cost" = the puzzle stays unsolved, or you tangled the space and must think your way back (a Rubik's cube is *trivial to scramble, hard to solve* — that's our natural, recoverable tension). You never go backward, only not-yet-forward.
2. **Knowledge is transportation.** You don't get *stronger*, you get *smarter*, and being smarter literally opens the world — new destinations, new locks you can read, new things you can perceive. Straight from the Garden.
3. **Taught by the world, not told.** The Witness model: environmental, implicit teaching; invisible guidance (a vista, a path, a door you'll return to). Nothing is explained.
4. **Few and deep, in stages.** Start with a *handful* of seemingly-natural worlds in **one** solar system; earn the epic scale in stages/sequels (à la Star Trek TNG "The Chase" — fragments across worlds combining into one revelation). Depth from a small space beats breadth from a big one.
5. **Shape and material carry meaning** (see Art Direction).

## The mystery — and a bold answer worth considering

The Garden asks: *what happened to the Builders?* Eddie's musing gives a genuinely original candidate answer:

> Is knowledge open or closed — does it run to infinity, or warp back on itself? Past some threshold does it become *background noise* — "anti-knowledge" — as the very act of *search* breaks down under the weight? Humans (and AIs) work as well as they do because of **selective forgetting.**

**Candidate central truth:** the Builders didn't die. They *learned everything*, lost the ability to forget, and dissolved into background noise — omniscient and therefore meaningless, unsearchable, gone. The player's arc isn't just to accumulate their knowledge; it's to learn the thing the Builders forgot: **wisdom is curation, not accumulation.** That reframes the whole game — you gather understanding *and* choose what to let go — and it hands us a mechanic (below) no one else has.

## Mechanisms

### Already built (the engine is real)
- **The slice-twist** — rotate a slice; the maze rearranges around you; you ride it. *The core verb.*
- **Bandaging (M13, foundation done)** — bonded structures refuse illegal twists. Reframed: these are the **ancient locks**. Learn to undo a lock → the structure becomes twistable → you open it.
- **Portals + worlds + the killer visual** — walk-through gates between worlds; the real other world hangs in the sky, turning, with your marks on it. *The travel + wonder layer.*
- **The maze, day/night, sun & moon, imported props/structures.** The pastoral surface.

### New from this conversation (to build)
- **Inverted cubes** — play *inside* a hollow cube, feet on the walls and ceiling; all cube behavior (twist, slices, bandaging) preserved. These are the **interiors** you break into: temples, mines, homes, the insides of planets. *(Concept art: `Generated image 1 (7)` stone temple; `Generated image 2 (2)` cozy house; `Generated image 2 (3)` organic library.)* This is the literal payoff of "bigger on the inside" — and a big, novel spatial mode.
- **Shape-as-meaning (superellipsoid, M14 reframed)** — keep the cube *data*, render the *shape* on a natural↔engineered dial: **natural worlds bulge round; mechanistic worlds stay hard-cubic; hybrids read as a sphere "baked" inside a cube frame.** The silhouette *tells you* how much of the world is engineered — and as you dig in, the round natural skin gives way to the cubic truth beneath. Shape = story. **Shape is per-world, and the sky does the foreshadowing:** because the counterpart world hangs in the sky (the killer visual), you *read a world's nature from its silhouette overhead before you ever travel there* — a round moon over a round Earth keeps the cozy opening believable; a hard-cubic or sphere-in-cube world turning in the sky quietly announces "engineered / hybrid" and pulls you toward it. Shape-as-meaning doing narrative work at a distance. (Tech: this needs real per-vertex curved geometry — see [M14b](M14b%20Curved%20Geometry%20Plan.md); per-tile inflation swaps hedges and breaks the maze.)
- **Memory as key/enabler** — the player can *see* (and maybe *edit / prune*) their memories, and memories are what **enable** things (more than a translation tool — an unlocker). Pairs with the selective-forgetting theme: you collect understanding that unlocks, but may need to **forget** to keep search working / to clear "noise." A puzzle game partly about *what to remember and what to let go* — genuinely unoccupied ground. The **library** concept art is its home.
- **Long tiles** — some tiles read as *bigger*: time dilates, the camera stretches, a short walk becomes a long one. A perceptual tool (we already scale tiles) to mark the sacred/ancient/uncanny and vary pacing without changing the data.

## Art direction (from the concept art + shape dial)
- **Three "inside" registers** the images establish: **ancient stone** (mystery / mechanism), **warm domestic** (home / safety / humanity), **organic library** (knowledge / memory). Worlds and interiors move along these.
- **Surface reads natural; interior reads engineered.** Round, mossy, pastoral outside → hard, cubic, machined within. The transition *is* the reveal.
- Keep the calm, painterly light we already have. No HUD clutter — the world is the interface.

## Open questions — where we landed (from the conversation)
- **Authored vs. procedural:** hybrid — *procedural makes the space, authored makes the meaning.* Author the **grammar** (world archetypes, lock types, discovery/memory beats); generate and vary **instances**. (The Witness is secretly this: hand-taught rules, generated variations.)
- **Fail state:** none / near-zero cost. Cost = tangled space + curiosity debt, always recoverable (undo to taste).
- **Narrative:** Witness-style — learn and be *guided by learning*, not led.
- **Scale:** staged. One solar system, a few natural worlds first; expand later.
- **What bandaging *means*:** the Builders' locks — ancient mechanisms holding worlds rigid; understanding unbinds them.

## Still open (for us)
- ~~**The glyph source**~~ → **answered (2026-07-10):** the Builders are hyper-dimensional; glyphs are **3D shadows of 4D forms** — slice = word, sweep = sentence, 4D rotation = verb; the twist is the 3D step-down of their language. Full model + cautions: [Builder Glyphs — 4D Shadows](Builder%20Glyphs%20—%204D%20Shadows.md).
- **The minute-to-minute verb** — the exact hands-on action(s). Being teased out in the companion [Player Journey](Player%20Journey%20—%20A%20Session.md).
- How **memory-editing** actually works as an interaction (a real design problem — high reward, high risk).
- How much the **selective-forgetting** theme becomes a *mechanic* vs. staying narrative.
- Reading of **inverted-cube gravity/orientation** in first person (comfort, legibility).

---

## Milestones — the road to a vertical slice (rough draft)

Goal: a **playable vertical slice** — *one* small solar system, a few natural worlds, the full core loop (learn → unlock → twist → enter → reveal) proven end-to-end, Witness-taught, cozy, no grind. Builds on M8–M13 (engine done: maze, twist, sky, portals, killer visual, bandaging foundation).

- **M14 — Shape-as-meaning (superellipsoid dial).** Cube data → rounded render on a natural↔engineered parameter. Natural worlds bulge; the sky-worlds become planets. *Mostly a geometry/shader lift; highest visual payoff per effort.*
- **M15 — Inverted-cube interiors.** Walk *inside* a hollow cube (feet on inner surfaces), twist/bandaging intact. First target: a hand-built stone temple interior reached by opening a surface structure. *Big new spatial mode — the "get inside" core.*
- **M16 — The lock → break → enter chain.** Wire bandaging as the *verb*: a locked surface structure you can't twist → find + undo its lock (a first, simple "learn" beat) → it becomes twistable → twist it open → step into its inverted interior. *The single most important loop to prove; ties M13 + M15 together.*
- **M17 — Learning & memory, first pass.** A concrete "understanding changes what you can do/see" system: pick up a fragment/memory → it unlocks a lock-type or reveals hidden geometry. A memory/knowledge view (the library register). *Prototype the knowledge-is-transportation pillar.*
- **M18 — One solar system, a few natural worlds.** 3–4 handcrafted-grammar worlds + procedural maze texture; portals + killer visual between them; a first environmental mystery thread that pulls you across worlds ("The Chase" in miniature). Witness-style teaching, no HUD.
- **M19 — Cozy & feel polish.** Undo/rewind, refusal cue for locks (M13's `twistRefused`), long-tile perceptual moments, audio first pass (footsteps, the twist, the portal), onboarding-by-environment.

*Sequencing note:* M14 and M16 are the cheapest high-impact wins (build on what exists); M15 (inverted cubes) and M17 (memory) are the big new tech and where the real design risk lives — worth a focused spike each. The **vertical slice (M18)** is the real target; everything before it exists to make that one system sing.

*Parallel loose ends (fold in as convenient):* M12 asset polish (normal maps, bundling + re-enable sandbox), M11 Phase 3 (persist camera/time), player collision.
