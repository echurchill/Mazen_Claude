# NPC Classes — design capture (not yet on a milestone)

*Captured 2026-07-08 from a design conversation with Eddie. The game will eventually need NPCs; this records the classes and the design threads each opens. Companion to the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and [Player Journey](Player%20Journey%20—%20A%20Session.md). Status: **design captured, no implementation** — several explicit "more thoughts needed" and one parked "pile of worms" (see §Open worms).*

## The organizing axis: how memory lives

The classes below sort cleanly along **where knowledge/memory resides and how it fails**:

- **Machines/computers** carry **external, networked** memory — knowledge that lives *between* nodes. Objective-ish, but with **holes** (freshest source is the least complete). You *query* it.
- **Biologic beings** and **Builder remnants** carry **internal, fallible** memory — knowledge that lives *inside one being* and degrades, misremembers, self-edits. Subjective, unreliable, possibly wrong. You *interpret* it.

That contrast is the point: it turns the whole NPC layer into the **selective-forgetting theme wearing faces** — a queryable knowledge graph with gaps on one side, unreliable narrators on the other.

---

## Class 1 — Machines / computers

Interactable technology, tiered by **connectivity**, where connectivity gates **how current the knowledge is**:

- **Isolated** — a lone machine, frozen at whatever it knew when it was cut off. A time capsule: possibly *detailed* but *stale*.
- **World-network** — connected to its planet's net; shares that world's knowledge, but the *whole world* may itself be stuck in time.
- **Inter-world network** — the widest, most current view — but *because* it's the aggregate, it's **missing** the parochial/lost knowledge trapped in isolated machines and stuck worlds.

**Why it matters (design):** this is a **diegetic knowledge graph with holes**, and the holes are the gameplay. The freshest source is paradoxically incomplete, so the player must **travel and cross-reference** — query the inter-world net for the *shape* of a thing, then hunt the one isolated box that still remembers the *detail*. That's *"The Chase"* (fragments across worlds combining into one revelation) rendered as a queryable system. It also:
- feeds the **knowledge-is-transportation** pillar (a machine unlocks you by *telling* you something), and
- is a natural **Rosetta surface** for teaching the Builder glyph-language (machines pair glyphs with meanings).

### Sub-idea — embedded machines (props & portals) — *more thoughts needed*
Not every machine is a discrete character you walk up to. Some are **ambient intelligence baked into world objects** — a prop, a dial, a **portal**.
- Example: a **portal that remembers where the player went**. This makes portals **nodes/edges in the knowledge graph**, not just doors — traversal is logged, so part of the network's memory is *built from the player's own movement*.
- Rhymes with the **killer visual** (twists already bake into the world hanging in the sky) — now *traversal* leaves a mark too; the world remembers you.
- Teaching/withholding surface: a remembering portal can **guide** ("others went this way") or **mislead by staleness** (a stuck-in-time portal remembers a route that no longer exists — a lie by age, not malice).
- **Open question:** where does embedded-machine memory sit between *world state* (which we already persist) and *NPC knowledge* (queryable, fallible, teachable)? That boundary needs its own pass.

---

## Class 2 — Biologic beings — *tentative, may be cut*

Living inhabitants of the worlds. Flagged as **possibly not a fit** for this game (cozy, no-combat, knowledge-led). Parked as tentative — revisit once the Builder-remnant class is designed, since they share the "internal fallible memory" model and may fold into it or be dropped.

## Class 3 — Builder remnants (post-biologic) — *near-certain we need these*

The Builders themselves, or what's left of them. Almost certainly required — they're the authors of the whole mystery, and the **memory-motes** already in the [Player Journey](Player%20Journey%20—%20A%20Session.md) are implicitly *them*.

**Why they matter (design):** carrying **internal, fallible, self-edited** memory, a Builder remnant who half-remembers, contradicts the network, or has *deliberately pruned* something is the **emotional core of "wisdom is curation, not accumulation."** This is where the selective-forgetting theme stops being a mechanic and becomes a **character** — an unreliable narrator whose gaps are meaningful, not bugs.

**Grounding mechanism (2026-07-10, from [Builder Glyphs — 4D Shadows](Builder%20Glyphs%20—%204D%20Shadows.md)):** a Remnant is a persistent **4D structure**; the "being" you meet is its *intersection with your 3D space*, and **different visits intersect different parts of it**. Its fallibility needs no hand-waving — you're never talking to all of it. Background: [The Builders v3 doc](The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx) ("a conversation with one Builder may involve only a tiny projection of an intellect").

---

## Open worms (parked — do NOT investigate yet)

- **LLM-backed behavior for Classes 2 & 3.** Fallible internal memory, interpretation, dialogue that isn't lookup — these plausibly want an LLM. That's a real design/architecture/cost question we are **explicitly not opening yet.** Flagged "needs figuring out eventually."
- **Co-worker docs to fold in.** Eddie has more detailed documents (from a co-worker) relevant to Classes 2 & 3. **TODO: get the paths/names and link them here** before we tackle this pile.
- **Embedded-machine memory boundary** (see Class 1 sub-idea) — world-state vs. NPC-knowledge.
- **Do biologics survive?** Decide whether Class 2 is real or collapses into Class 3.

## How this ties to what exists / what's planned
- Knowledge graph + glyph teaching connect to the **"understand" verb** craft questions in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) (§Live design questions).
- Fallible/edited memory connects to the **memory-as-key** and **selective-forgetting** mechanisms, and to a possible future **forgetting-as-verb** (anti-locks).
- Embedded portal-memory connects to **M11** (worlds & portals) and the killer visual.
- No milestone number yet — this is pre-milestone design capture.
