# Builder Glyphs — 4D Shadows (design capture)

*Captured 2026-07-10 from a design conversation with Eddie. Answers the open "glyph source" question from the language keystone thread (see [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) §Live design questions). Background source: [The Builders of Garden of Worlds — Transcendent Civilization v3](The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx) (Eddie + ChatGPT — potential background material, not canon-as-is). Status: **adopted as the working glyph model**; rendering model = **caustic projection + a
comprehension gradient** (2026-07-13, see that section); message bundling = **the frame cube is the
cartouche; the vase is a sentence made solid** (2026-07-15, see that section); the plinth is a
**waldo for the world** (2026-07-15 — mechanism, not signage). Spike re-scoped from the caustic
plaque to **the plinth** (the M16 lock's tutorial): first cut landed 2026-07-15 (M16.6), unreviewed.*

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

### The forge tool as a living vocabulary sketchpad (Eddie, ongoing)

[computational-caustic-projection.html](computational-caustic-projection.html) is where Eddie is
**accreting the symbol vocabulary** — targets so far include the game's own iconography (the
police-box **portal**, the **obelisk**) alongside two-spots / star / solar-system / ringed-planet.
More symbols get added over time to think the glyph concept through. Two things this surfaces:

- **The world is the Rosetta stone.** Glyphs that project *things the player has seen* (a portal, an
  obelisk, a ringed planet) teach the first "words" diegetically — the payoff is "that shape is a
  *thing I know*." The language's vocabulary literally is the world's contents.
- **Two registers — pictograms vs. the abstract grammar** (design question, held not decided). The
  tool's symbols are **pictograms** (the caustic *shows a thing*); the canon's grammar is
  *transformation* (slice=word, sweep=sentence, rotation=verb — abstract forms whose meaning is
  learned). Not in conflict: concrete pictograms can be the **nouns** the player reads first (the
  on-ramp), abstract slice-forms the harder **verbs** later. The comprehension gradient rides this —
  first you make out concrete depictions, only later grasp the abstract relations between them.
  Each added symbol also quietly probes the **discrimination ceiling** (do two symbols caustic into
  distinguishable images at full attunement, or collide into similar blobs?).

*When the symbol set grows enough that a pattern emerges (which shapes stay crisp, which collide,
which feel noun vs. verb), fold a short "vocabulary findings" note in here.*

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

## The cartouche — the frame cube (Eddie, 2026-07-15)

Second tool, in this folder: [caustic-frame-cube.html](caustic-frame-cube.html). It takes a series
of caustic shapes and **lofts them into a single solid**: 10 keyframe glyphs
(`box, focus, star, double, ring, triple, planet, spiral, solar, stickman`), 20 lerped frames per
transition → **181 transparent 512² slices** stacked along Z inside a rotatable **wireframe cube**.
From the side it reads as a **vase**; from above, a **layered stack of glyphs**.

**The cartouche is the FRAME.** This answers the open "how do you bundle symbols into a
cartouche/sentence" question — and the answer isn't a symbol. An Egyptian cartouche is the
*enclosing loop* that declares "these marks are one name, read together." The wireframe cube does
exactly that job: it bounds the stack and says *this is one message*. (Eddie's hand-bent wire cube
is that frame in the flesh.)

**The vase is the sentence made solid.** The [grammar table](#the-generator--grammar-falls-out-of-the-geometry)
already had cross-section = word, sweep = sentence. The frame cube **freezes the sweep along an
axis**: the vase's horizontal cross-sections *are* the words; the vase *is* the sentence. No canon
revision — the same grammar, rendered as an object you can hold.

**Therefore reading = a light plane sweeping the vase.** Decoding is illumination at successive
heights — literally taking cross-sections. The late-game decoder tool doesn't merely *use* the
grammar, it **is** the grammar. Cheap, too: the runtime already forward-projects a field; the tool
only animates which frame is lit.

**Plinth and vase are ONE system at two message lengths.** Plinth = 1 layer (a word). Vase = 181 (a
story). Same object, same shader; length is the only variable.

**Emergent — the silhouette is a signature.** A vase's profile is the *envelope of its word
sequence*, so **different messages make different vase shapes**: readable at distance before a
single glyph resolves, and a free discrimination layer ("the pottery style IS the sentence").
Corollary: if all vases look alike, all messages are too similar.

### The first Builder text (the tool's sequence, glossed by Eddie)

| glyph | role |
|---|---|
| `focus` + `star` | quantifier + noun — *a star* |
| `double`, `ring`, `triple`, `planet` | *2 planets, 3 ringed planets* |
| `spiral` | **verb** — *swirled together* |
| `solar` | result — *into a solar system* |
| `stickman` | subject — *where a person / humanity lives* |

Opening quantifier-noun pairs, a verb, a result, an inhabitant: **syntax, not a slideshow.** And
it's a **creation story** — the Builders' account of assembling this solar system, ending in *where
humanity lives*. The game's central reveal (natural surface → engineered truth) stated as plain fact
on a vase the player walks past in world 1 and cannot read for twenty hours.

It also validates ["the world is the Rosetta stone"](#the-forge-tool-as-a-living-vocabulary-sketchpad-eddie-ongoing)
hard: **every noun in that sentence is visible in the sky** — the star, the planets, the ringed
planet, the solar system, the player themselves. The vocabulary *is* the world's contents.

> **Provenance note (Eddie, 2026-07-15):** the leading `box` glyph was **an accident** — left in the
> tool's code, with the "start of memory" prose retro-fitted to it. Not canon. The idea it
> accidentally suggested is worth keeping as a **candidate, clearly unproven**: that the first glyph
> is a **type marker** declaring the message's genre (`box` = memory/story; its absence =
> instruction). The plinth messages below carry bare marks with no `box`, so the distinction is
> already implicit in the design if we want it. Eddie's call; don't treat it as decided.

**The swirl is not a placeholder.** It appears in the vase sentence (*swirled together → a solar
system*) and on the portal plinth (*swirl → you twist → a portal*). Same verb, different object:
**turn/combine to produce.** That consistency across contexts is what makes a generative system feel
real rather than a cipher table — and it lands exactly on the grammar's **4D rotation = verb** row: a
verb drawn as the operation it names. We already have the "Q glyph"; stop looking for one.

**The dots quietly resolve the gradient-vs-tutorial tension.** The [comprehension gradient](#the-comprehension-gradient--mushy-is-the-mechanic-not-the-bug-eddies-key-reframe)
says early = mushy blobs, but a tutorial must be legible — those fight. Except **a mushy dot is
still a dot**: counting survives arbitrary defocus. So the first words read at *zero* attunement
without weakening the gradient, and it's diegetically right (numerals are what real decipherment
cracks first). Generalised rule: **choose blur-robust shapes for the first words** and the gradient
costs nothing. Watch `focus`/`double`/`planet`/`star` though — all blob-space; *star vs planet* is
where the [discrimination ceiling](#legibility--the-honest-caution) bites first.

## The plinth — the tutorial puzzle (Eddie, 2026-07-15)

The plinth (a trapezoidal base with a lit disc on top, casting a caustic) **replaces the
`glyphPlaque`** and stands beside each switch. It maps onto the M16 lock we already have, with no
mechanic changes:

| existing | plinth says |
|---|---|
| four `.dial`s in the garden's diagonal quarters (M16.3) | **1, 2, 3, 4 dots** — one ordinal each |
| all dials aligned ⇒ the temple's bond dissolves (M16.3) | portal plinth: blank → **swirl** |
| a twist of the unlocked door's slice swings it open (M16.4) | player twists (Q) → portal plinth shows the **portal** |

**Why this is the whole language in miniature.** The switch plinths teach `focus`/`double`/`triple`
— *the exact morphemes the vase sentence needs*. The player learns "two dots = two" on switch 2 in
world 1; twenty hours later that same glyph reads **"2 planets"** on a vase. The tutorial isn't
adjacent to the dictionary, it **is** the dictionary entry — the Rosetta closing for free.

And the portal plinth **teaches a verb by consequence, with no UI text**: the glyph names the
action, you perform it, the glyph updates to the result. "Understanding rewrites perception" as a
tutorial loop.

**DECIDED (Eddie, 2026-07-15):** the ordinals are **teaching-only — the puzzle is unchanged.** The
goal is simply to start introducing the numbers; M16.3 keeps shipping three pre-aligned and one off
("find the pattern and act once"). The numbers are vocabulary, not a combination.

## The plinth is a WALDO for the world (Eddie, 2026-07-15)

Eddie's reframe: the plinth isn't signage, it's **mechanism** — a master–slave remote manipulator.
(A *waldo*: Heinlein's 1942 novella, whose protagonist is too weak to touch the world and builds
remote hands he drives from a harness; engineers took the word and built the real thing — Goertz's
hot-cell manipulators at Argonne, reaching through a shielded wall so the operator stays safe
behind it. Defining traits: **correspondence**, **force reflection**, **scaling**.)

**The sign becomes the switch.** The swirl means *turn/combine to produce* — and it's engraved on
the very thing you turn. The glyph doesn't describe a verb happening elsewhere; it **labels its own
control**. Language and mechanism collapse into one object, which is how real interfaces earn their
symbols.

**The force reflection already exists.** M16.2 — the slice strains against the lock and springs back
(camera wobble), "the cue that teaches *locked* without a word of UI." That *is* bilateral force
reflection, the defining waldo trait: the world pushes back through the control. Already shipped;
the plinth only gives that resistance a body to travel through.

**Scaling is the thesis, not a detail.** A waldo exists so a small gesture moves what the operator
couldn't. A finite hand turning a world is the game's own claim about limitation ("the player's
limitation is the searchlight") stated as hardware. It also rhymes with the
[step-down thesis](#the-generator--grammar-falls-out-of-the-geometry) — face:cube :: cube:tesseract —
a waldo is *literally* a step-down device.

**Every waldo implies an ABSENT OPERATOR.** A control surface is evidence that someone isn't here.
Plinths scattered across the worlds are a landscape of abandoned controls — the **lost stratum
stated in hardware** rather than lore. Same move as the vases (the archive was always there,
unreadable), but for *mechanism* rather than *message*.

It also fits the Builders' ethic without being told to: **hidden-by-ethics** gives a control surface
that looks like landscape furniture; **restraint over omnipotence** gives hands sized for *us*, not
for them.

### Who is operating whom — hold BOTH (not to be resolved)

| reading | the plinth is… |
|---|---|
| the player reaches into a world too big for them | **the player's** waldo |
| something finite is being reached *through* | the player is **the Builders'** waldo |

The endgame seed (last section) — the created reminding the creators, the introduction composed in
the glyph language the player learned — makes the second reading land hard. Note the
inversion: Heinlein's Waldo is a mind too **weak** to touch the world; the Builders are minds too
**large** to. Same device, opposite direction.

### Taxonomy — keep these honest

| | what it is | what it must NEVER do |
|---|---|---|
| **vase** | a word / a record | control something |
| **plinth** | a hand / a control | tell a story |

The Builders left both *words* and *hands*. Blur them and each stops meaning anything.

### Does a twist require a plinth? — ANSWERED by the ladder (Eddie, 2026-07-15)

Yes, early — then progressively not. See
[the ladder](#the-ladder--this-answers-the-gating-question-eddie): **magic → plinth → portable waldo →
none.** So gating is a *stage*, not a rule: twists start located and authored (you may only turn the
world where the Builders left a handle) and open up as the player gains fluency — which lets
**M18/M20's free twisting** be the late state rather than a contradiction. The comprehension gradient
therefore pays out **mechanically**, not just visually: understanding rewrites *capability*, not only
perception. **Still open:** the fork at the top of the ladder (portable device vs. no device).

## Teaching the twist — the alignment cylinder (Eddie, 2026-07-15)

The problem Eddie set: **slow-teach the world-twisting dynamic without exposing too much too soon.**

His answer: when the swirl appears, the plinth's display **grows taller into a cylinder** — a top half
and a bottom half, each carrying a mark. Engaging it (tap / Q / …) pivots the halves until the marks
**align**. As they align, **the world twists**: a loud grinding, the screen shakes, the sky shifts —
*"after all it has been a while since this last happened."*

**Why it teaches:** the cylinder is a **scale model of the world sitting on the plinth**, so turning
the model turns the world. That's the waldo's first trait — **correspondence** — made physical, and it
lands in one gesture with no words. Crucially the player **doesn't need to understand slice rotation;
they need to align two marks.** The twist is the *consequence* — the same consequence-teaching loop as
the door plinth (glyph → act → glyph updates), with the whole world as the payoff.

### The haptic channel — resist vs grind

| the world says | how it says it |
|---|---|
| **no** | strain, springback, camera wobble — **already shipped** (M16.2) |
| **yes, but I am old and heavy** | grind, shake, the sky lurches |

One channel, two messages, zero UI. And "it has been a while since this last happened" isn't flavour:
it's **characterisation through resistance** — the machine tells you its age by how hard it is to turn.
(Both are the waldo's second trait, **force reflection**.)

### The Portal frame — and why ours is the stronger version

Eddie's anchor: Portal's first room, where a portal *just happens* and you don't own it; eventually you
get the gun. Ours differs in a way worth keeping deliberately:

| | what the player has |
|---|---|
| Portal, room 1 | **the effect, with no agency** — it happens behind glass, you watch |
| the plinth | **agency, with no comprehension** — *you did that, and you don't know what you did* |

For a cozy, no-fail game ours is better: the player acts first and understands later, which **is** the
dog/fetch relationship — the dog fetches long before it knows what "fetch" means.

### The marks — two halves of a glyph: the SQUARE

Red/green was **rejected** (Eddie agreed) for two independent reasons:
- **Diegetic:** why would hyper-dimensional Builders use human traffic-light semantics? Their language
  is geometry, not RGB convention.
- **Accessibility:** red/green is the single most common colourblind axis (~8% of men). A tutorial the
  player cannot fail must not be one they cannot *read*.

Both die to the same fix: **position already carries the signal** — the marks physically line up. Let
geometry be the message and colour be decoration.

Arrows were considered and dropped: **an arrow is UI ("align me"), a square is language ("world").**
Since the tutorial *is* the dictionary entry, pick the mark that adds a word — an arrow can't.

**The square is not a metaphor, it's the geometry.** `square : cube :: cube : tesseract` — a square is
what a cube casts, a cube is what a tesseract casts. So the square is the shadow-of-a-shadow of the
Builders' world-object, and it is the most literally visible noun available: **the player is standing
on a cube whose faces are squares.** The Rosetta principle at its most direct.

> **Which gives the cylinder a sentence.** The cap already carries the **swirl** (verb: *turn/combine
> to produce*); the barrel assembles the **square** (object: *world*). Complete it and you have said
> **"TURN THE WORLD"** — a two-word imperative that you complete *by obeying it*. The sentence doesn't
> describe the action; **the action finishes the sentence.** (Straight off the grammar's own rows:
> rotation = verb, cross-section = word.)

*Tabled (Eddie): the **hourglass** as the glyph for time — we aren't manipulating time yet. Worth the
back pocket, though: an up-arrow meeting a down-arrow **is** an hourglass, so if time ever becomes
manipulable, the geometry already implied the glyph.*

*Staging note: dots/circles stay right for lesson one (blur-robust — a mushy dot is still a dot). The
square-halves is the step after. The tutorial's shape has room to grow into the language.*

### The ladder — this ANSWERS the gating question (Eddie)

| rung | the player… |
|---|---|
| **magic** | it happens *to* them; they don't own it (Portal's first room) |
| **plinth / waldo** | operates a Builder's handle — located, authored twists |
| **portable waldo** | carries their own hand (a "Pipboy"-ish device) |
| **none** | reaches directly |

Better than the earlier training-wheels proposal, because the first rung is *"it happens and you don't
own it."* **The fork at the top is still open:** a portable device **or** enhancing the player until no
3D device is needed to manipulate the 4D mechanisms within/between worlds.

### Fluency, not capacity — the constraint on that fork

Whichever way the fork goes, **the enhancement must raise vocabulary, not capacity.**

The endgame's entire logic is that an omniscient mind *can't* find pattern in noise while a small,
finite, **curating** mind can — "the player's limitation is the searchlight." Enhance the player toward
Builder-scale and **we destroy the very finitude that makes them the only one who can do the job.**
The dog learns more words; it never becomes human. **Keep the ceiling, raise the fluency.**

Corollary for the Pipboy branch: **a Builder waldo is a hand, not a menu.** The moment it becomes an
inventory screen it has stopped being a waldo.

### Open — the taxonomy tension

The control now *looks like* the message: a cylinder on a plinth vs. a cylinder standing alone. Either
that's a bug (players can't tell a word from a handle) or it's deeply in-theme (**you can't tell a
Builder's word from a Builder's hand**). Decide on purpose, not by accident.

## Numbers — the Builders don't have hands (Eddie, 2026-07-15 — OPEN)

Eddie's observation: decimal is almost certainly an **anatomical accident** (two hands, five fingers).
Post-biological, hyper-dimensional beings have no fingers — so **we count on our hands; they'd count on
their world**, and whichever base they use is a *fingerprint of the shape they think in*.

**Two things that make this safe to leave open:**
- **The existing design already constrains it: the base must be > 4.** If it were 4, the fourth dial's
  plinth wouldn't be four tallies — it would roll over into positional notation. So 6, 8, 12, 16, 24
  survive; 2 and 4 don't.
- **It's deferrable.** At 1–4 *every* base looks identical (small numbers are tallies in essentially
  all real systems). A base only becomes visible at the first number **≥** itself, which lives deep in
  the vase archive. **Nothing shipped now forecloses the choice.**

*Claude's suggestion, for Eddie's consideration:*

- **Base 16 — the corners of a tesseract.** Not for elegance: because **the player's most reasonable
  guess is wrong in exactly the way that reveals the answer.** They live on a cube; a cube has 8
  corners; so they'll try 8 — and fail, because the Builders counted the corners of *their* world.
  *You counted the corners of your world; they counted the corners of theirs.* The off-by-one-dimension
  error **is** the revelation — and it delivers [the doc's promise](#the-premise)
  that a fan who realises "these are tesseract sections" gets the character's revelation, except through
  **arithmetic**, which is falsifiable and crackable rather than vibes. It also makes their counting
  **dimension-stacking**: an n-cube has 2ⁿ vertices, so 1, 2, 4, 8, 16 is binary *because each new
  dimension doubles your corners* — a geometric soul, not a silicon one.
- **Runner-up: base 24.** The 24-cell is the one regular polytope that exists *only* in 4D — an
  unforgeable signature of four-dimensionality — and 24 is gorgeously composite (2,3,4,6,8,12 divide
  it), which a civilisation doing orbital mechanics would want. Second only because 16 is *learnable*
  and "corners of a hypercube" is graspable, where 24 needs you to already know what a 24-cell is.
- **Reject:** base 2 (reads as *computer aliens* — loses the geometry), base 12 (finger-joint counting;
  too human), decimal (the accident we're escaping).

## The vase archive (Eddie, 2026-07-15)

Vases scattered around the worlds, meaningless on sight; late-game the player gets the decoder tool
and **goes back** to read the Builders' whole story. Two constraints this needs:

- **Placement scattered, content AUTHORED.** Found out of order, the archive must be *assembled* —
  curation becomes the literal reading mechanic ("wisdom is curation" as verb, not moral). But
  procedurally generated vase content would be **noise**, and noise is load-bearing elsewhere (the
  lost stratum is precisely the stuff you can't grep) — don't let accidental noise blur a real
  distinction.
- **Findability.** "Go back to them" only works if the player can: either a journal logs vases as
  you pass, or they sit at memorable landmarks. Otherwise the late game is a wander.

### Scoped spike — the plinth (supersedes the caustic-plaque spike)
The plinth is a **cheaper first step** than the previously scoped plaque and de-risks the same
render path on the tutorial: one static field, forward-projected, **no morph and no blur required**
to ship the first version; the switch-state → glyph swap is just swapping fields. The morph and the
attunement blur then land on the same shader as upgrades, and the vase is that shader with a long
field sequence and a moving light plane.

Note the tutorial symbols (1–4 dots, swirl) are simple enough that **their caustics need no inverse
solve at all** — a target point-set splatted as soft blobs is the forge's own poor-man's transport,
minus the solver. Blob radius then *is* the sharpness dial, so the comprehension gradient falls out
for free. **Eddie: this is a "very important aspect" that will need real prototyping to feel right.**

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
