# Builder Glyphs — 4D Shadows (design capture)

*Captured 2026-07-10 from a design conversation with Eddie. Answers the open "glyph source" question from the language keystone thread (see [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) §Live design questions). Background source: [The Builders of Garden of Worlds — Transcendent Civilization v3](The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx) (Eddie + ChatGPT — potential background material, not canon-as-is). Status: **adopted as the working glyph model**; rendering model = **caustic projection + a
comprehension gradient** (2026-07-13, see that section); prototype ("glyph forge" + caustic
plaque spike) unscheduled.*

## The premise

The Builders are **post-biological, hyper-dimensional** beings (the Q / Alterans / Star Maker / *Permutation City* lineage — they likely didn't start that way). They communicate in hyper-dimensional forms; they could never leave us 3D *words*, only **3D shadows of 4D thoughts**. The memories they left — possibly the Remnants of their minds themselves — are *3D representations of 4D messages*. Eddie's seed image: a 3D representation of a 4D Rubik's cube.

**Players never need to do 4D reasoning.** The 4D system is the *author*, not the mechanic (Miegakure is the cautionary tale for the latter). Players learn shadow-family ↔ behavior correlations through the Rosetta memory-motes; the 4D truth is the deep layer for lore-divers — and for the fan community, which wouldn't be cracking a cipher table (Fez) but reverse-engineering a **generative system** (beyond Tunic/Outer Wilds): every fan who realizes "these are tesseract sections" gets the same revelation the player character gets.

## The generator — grammar falls out of the geometry

This solves the glyph-authoring cost problem (a hand-built conlang grammar is expensive and, if thin, decays into find-the-switch lookup). 4D→3D projection is a *structured generative source*: glyphs look meaningful because they **are** — shadows of a coherent higher object. The grammar we required (relationships/transformations, not nouns) is native:

| 4D operation | 3D result | Linguistic role |
|---|---|---|
| **Cross-section** (frozen slice) | a crisp, closed 3D form | a **word** — carvable on a lock |
| **Section sweep** (the object passing through 3D space) | a morphing shape sequence | a **sentence** — what a memory-mote *plays as*: the vision IS the message crossing your space |
| **4D rotation** (incl. double/isoclinic — no 3D equivalent) | an alien transformation | a **verb / operator** |
| **Slicing axis choice** | different sequences from the same object | morphology — tense/aspect/dialect from geometry alone |

**The thesis this hands us:** slicing a hypercube rearranges whole 3D *cells* exactly as our twist rearranges 2D faces — face:cube :: cube:tesseract. **The player's twist is the 3D step-down of the Builders' language.** Reading a lock's glyph and performing the twist that answers it are the *same verb at different dimensions* — the "mechanic is the theme is the progression" loop closes at the linguistic level. (Held loosely: the solar system's worlds as cells of a tesseract, portals as 4D adjacencies — rhymes with the [World Graph](World%20Graph%20—%20Relational%20Worlds.md); don't commit to the cosmology yet.)

## What it mechanizes (themes that were vibes become geometry)

- **Selective forgetting:** a 3D mind *cannot hold* a 4D idea — you can only keep a projection. **Forgetting = choosing which slice to keep.** "Wisdom is curation" stops being a moral and becomes dimensional necessity.
- **Remnant fallibility** (NPC class 3): a Remnant is a persistent 4D structure; the "being" you meet is its **intersection with your space — and different visits intersect different parts of it.** Not lying, not senile: you're never talking to all of it. (The Builders doc independently converges: *"a conversation with one Builder may involve only a tiny projection of an intellect whose complete awareness spans countless worlds and eras."*)

## Legibility — the honest caution

Raw 4D projections read as generic sci-fi hologram noise; wireframe tesseracts are the poster child. Failure modes: projections of the *same* object look wildly different (recognition breaks); projections of *different* objects look alike (discrimination breaks). Glyphs must be glanceable, memorable, hand-copyable into a notebook. Mitigations (all cheap):
1. **Cross-sections, not wireframe projections**, for static forms — slices of 4D solids are crisp closed shapes.
2. **Canonical slicing axes** per word; a **small primitive set** (start with the hypercube family).
3. A consistent **carved register** — stone linework, not floaty holograms.
4. **Animation reserved for sweeps/verbs**, taught via motes; carvings stay frozen.

## Rendering the glyphs — caustic projection + the comprehension gradient (Eddie, 2026-07-13)

Eddie's proposal: render glyphs with **Computational Caustic Projection** (a Metal shader). A
caustic is *light designed by a surface* — shape a transparent/reflective plate so uniform light
reassembles into a target image (the bright curves at the bottom of a glass, computed on purpose).
That is **exactly what a Builder message is**: shaped matter that only reveals meaning when
illuminated/read. The artifact looks like inert etched structure; the meaning is invisible until
you know how to cast light through it — the game's "understanding rewrites perception" at the
material level. (Working tool, made by Eddie+ChatGPT, in this folder:
[computational-caustic-projection.html](computational-caustic-projection.html) — it produced the
two-spots / star / solar-system / ringed-planet demos; a poor-man's optimal transport via
Morton/Z-curve sorting of source cells to target-shape points, then lerp the targets to morph.)

**This UNIFIES with the "3D shadow of 4D" canon via a three-layer model — one layer per dimension
of understanding:**

| Layer | What it is | In the fiction |
|---|---|---|
| **4D** | the true message | the Builders' actual meaning — never directly seen |
| **3D** | the **plate** (the shadow of the 4D form) | the physical artifact you find, hold, rotate — the "3D shadow" the canon already had |
| **2D** | the **caustic** (what the lit plate projects) | the readable slice — the "word" you can actually see |

A 4D message casts a 3D plate; the plate casts a 2D caustic. The learning arc drops *down* through
the layers: first you read flat 2D caustics (slices), later you see the 3D plate as a form,
eventually sense the 4D whole. "Ringed planet in a binary system" is one 2D slice of a bigger
message. And the twist earns its place at the render level: **rotating the 4D form cycles which
slice projects → the caustic morphs → reading the next word IS a twist** ("the twist is the
language's projector" — the [thesis above](#the-generator--grammar-falls-out-of-the-geometry) made
visual).

### The comprehension gradient — "mushy" is the mechanic, not the bug (Eddie's key reframe)

Caustics get mushy (the "solar system" demo is a blob-pile). Rather than fight that, **the blur IS
the alienness, and clearing it IS the "understand" verb.** First contact with a remnant message:
you make out only *parts* — vague blobs, a fragment of a shape. As you become **in-tune** with the
Builders' way (via motes / accumulated familiarity), the shapes sharpen — **but never to full
clarity.** You come to identify a few "words" and *guess the overall intention*.

> Eddie's analogy: a dog or bird learns what its human means by "fetch" — but only ever grasps a
> handful of words and guesses the rest of the intent; it never knows the full vocabulary. **The
> player is that dog to the Builders.** The irreducible residual uncertainty is the point.

This is thematically exact — it's the finite-mind-vs-hyper-dimensional gap *already* in canon
(Remnant fallibility: "you're never talking to all of it"). Mechanically: an **attunement** level
(global, and/or per-glyph-family familiarity — a [PlayerKnowledge](M17%20Work%20Plan.md) reading)
drives the caustic's **sharpness/focus**. Early = mushy blobs; later = crisp but with a hard
ceiling below "perfect"; different word-families sharpen at different rates. The render's weakness
becomes the exact comprehension dial — mushiness = your current understanding, deblurring = learning.

**What this does to the [legibility caution](#legibility--the-honest-caution):** it *relaxes* the
"must be instantly crisp" requirement (blur is now designed, staged by attunement) but **keeps the
discrimination requirement** — at full attunement, different words must still look different, and
the sharp target must be iconic/memorable. So the forge's job narrows: author plates whose
*fully-attuned* projection is a distinct, glanceable silhouette; the gradient handles the rest.

### Forge / runtime split (keep the hard solve offline)

- **Offline — the forge:** the expensive *inverse* solve (target image → deflection field) is that
  HTML tool's job. The Builder-word vocabulary is authored & finite, so we **precompute plates
  offline** and import the deflection fields as data. (The tool's Morton-sort transport is cheap
  enough it could even run at load if we ever want it.)
- **Runtime — cheap Metal:** a shader that **forward-projects** an authored deflection field (splat
  each cell's deflected ray into an intensity buffer — a compute pass or point-sprite accumulate),
  **lerps two fields to morph** between slices, and takes a **sharpness parameter from attunement**
  for the comprehension gradient. The inverse solver never runs at runtime. Live shader for hero
  glyphs (rotate the plate → the caustic responds in real time); precomputed flipbook textures for
  ambient ones.

### Scoped spike — the caustic plaque (self-contained, low-risk)
A Metal shader that forward-projects one authored deflection field onto a plane, morphs between two
fields, and blurs by an attunement value — rendered onto an in-game **glyph plaque** (a plate that
casts a shifting caustic on the surface behind it). Proves the runtime path, the morph, and the
comprehension-gradient look without touching the inverse solver. Port the tool's source→target
mapping as the offline precompute. **Eddie: this is a "very important aspect" that will need real
prototyping to feel right.**

## Prototype path (cheap)

4D rotations are literally `float4x4` acting on ℝ⁴ — the engine's native math. A small offline **"glyph forge"** generates candidate slice-families for human curation; results import as small meshes through the existing asset path — *or, per the caustic model above, as precomputed deflection fields the runtime shader projects.* Weekend-sized spike, unscheduled (naturally slots near M16/M17).

## Lore ladder (new canon from this conversation)

Natural worlds → *cracked* (revealed as constructs) → **hybrid** → **fully mechanical** → **womb worlds**: natural worlds not yet born, still in their mechanical womb. Womb worlds slot as late-game shape-as-meaning states — and something a lying sky ([World Graph](World%20Graph%20—%20Relational%20Worlds.md)) could foreshadow. Genre anchor: Magrathea (H2G2).

## The Builders background doc — what to take, and one canon tension

The [v3 doc](The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx) is *source material, not canon-as-is* (its own words). Strongest takes for us:
- **Hidden-by-ethics:** "the ideal Builder completes a work so seamlessly that future generations believe it emerged naturally" — this makes the game's core reveal (natural surface → engineered truth) **the Builders' own ethic**, discovered rather than explained. Perfect thematic lock-in.
- **Restraint over omnipotence** ("power measured by what is not done", preserving possibility over optimizing outcomes) — harmonizes with the cozy/no-fail pillar.
- **"They remember being finite… forgetting what it was like to struggle would make stewardship impossible"** — feeds the memory/forgetting mechanics directly.
- Two seeds the doc itself marks **non-canonical, keep dormant**: the *Living Lineage* (Builders as a stewardship passed across civilizations — younger ones ascend into it) and the *Builder Phase* (Builder as a developmental season, not a species; no narrative ceiling — "every horizon becomes someone else's beginning").

**Canon tension → resolved frame (Eddie, 2026-07-10): BOTH are true.** The living stewards (v3 doc) and the dissolved-into-noise (synthesis tragedy) are different strata of the Builders — **and the stewards do not know the lost ones exist.** Three mechanisms we already have explain the ignorance: (1) search breaks down against noise — you can't grep static; (2) the knowledge-graph-with-holes ([NPC Classes](NPC%20Classes.md)) — the stewards' networks have *civilizationally forgotten*; (3) **hidden-by-ethics cuts both ways** — a culture whose ideal is work seamless enough to be mistaken for nature never notices *someone else's* work among its own; the lost ones' constructs were attributed to nature or to each other.

**Candidate endgame arc (Eddie's soft pitch — a seed, NOT the committed goal):** the player's job becomes *reminding/introducing* — carrying the memory of the lost stratum to the stewards. Why the player and not a Builder: an omniscient mind can't find pattern in noise; a small, finite, **curating** mind can — *the player's limitation is the searchlight*, making "wisdom is curation" the literal plot mechanism, not just the moral. Speculative sparks (same seed status): the introduction is *composed in the glyph language the player learned* — the final twist is a word (and fulfills the v3 doc's Great Exchange: the created reminding the creators); **forget-to-carry** — holding the message that matters may require pruning hard-won knowledge (curation as the game's final personal ask); **womb worlds as evidence** — orphaned, untended gestating worlds are how the player proves the lost existed. Tone: the endgame is a **reunion**, not a battle. Decide firmly at M17/M18 narrative work.
