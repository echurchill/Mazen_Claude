# World Graph — Relational Worlds (design capture)

*Captured 2026-07-10 from a design conversation with Eddie, answering the structural question M15 forced: is an interior a view of the same cube, or a different world wearing its name? **Decision: separate worlds — with relational identity.** Companion to [Worlds and Portals Plan](Worlds%20and%20Portals%20Plan.md) (M11), the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md), and the eventual M15 plan. Status: design captured; the registry is the first build step of M15.*

## The model in one line

> **A world's identity is keyed by route, not just name:** a portal's destination is a function of `(where the door is, where you came from)` — Eddie's naming sketch: `<world_you_are_on>-<world_you_came_from>`. The world graph is directed and **edge-labeled**; a registry resolves each key to a world instance, creating it lazily and persisting its scars forever after.

## What this buys

- **Interiors are their own worlds** (TARDIS rules stand — bigger on the inside, no shared twist-state with the surface by default). Maximum flexibility for M15.
- **Variants for free:** the same temple door can yield a *different interior depending on approach* — different time periods, alternate realities, the moon-temple vs. the earth-temple. Multiple variants of a destination, each keyed by its origin.
- **Identity when it matters:** multiple keys may resolve to the **same instance**. This protects the killer visual's emotional core ("that's *my* tear up there"): **earth↔moon stay identity-bound** — one moon instance whether you're looking at it or standing on it. *Identity is a choice per edge, not a law of physics. Default: bound. Diverge only when the narrative wants it.*
- **Sky-worlds are edges too:** *what hangs in your sky* is also resolved through the registry, keyed `(observed, observer)`. Today it's the same instance you can visit — but a world seen from afar *could* resolve to a distant/idealized variant that differs from what you find on arrival. Shape-as-meaning foreshadowing with a knife hidden in it: **the sky can lie.**

## The M17 extension (noted now, built later)

If the edge key is `(destination, context)`, *context* need not stop at "world you came from" — it can eventually include **what the player knows**. The same door resolves differently once you carry a certain memory: understanding doesn't just unlock doors, it **re-aims** them. That makes the *knowledge-is-transportation* pillar literal, and turns the original Garden concept's "the portal network is a language" into architecture.

## Time periods & decayed portals (Eddie, 2026-07-11)

*The "variants for free" line above grows teeth: multiple earths and moons representing
**different time periods**, reachable because some portals can route across eras — either by
design, or because their tech has **decayed**.* It's Builder tech; of course some of it does
things its makers would call malfunction and we call time travel.

- **A time period is just a key component.** `earth@bloom-era` and `earth@ruin-era` are two
  instances in the registry sharing a stamp lineage — lazy-created, independently scarred, no
  new machinery. Portals route to *instances*, never to "the past of a live timeline," so
  there is **no paradox problem by construction**: changes in an old era propagate nowhere
  unless we *choose* to `bind()` an echo across eras. Paradox is a design dial, not physics.
- **Decayed portals = doors that lie.** A decayed portal's destination key has drifted or
  gone unstable (a wrong or wandering era component). Mechanically trivial; narratively gold —
  the companion to the sky-can-lie principle: **the door can lie too.** Decay states could
  range from "consistently wrong era" (a stable, exploitable bug) to "unstable" (era varies —
  use with care, or first understand its pattern).
- **Learning the tweak verb from a broken teacher.** The M17 extension below says knowledge
  re-aims doors; the decayed portal is how the player *earns* that verb — watch a broken
  portal do the "wrong" thing, understand *why* (its glyphs? its mechanism? its era dial?),
  and that understanding becomes the ability to deliberately tweak working portals. The best
  kind of Builder lesson: the curriculum is a ruin.
- **NPC tie-in:** the memory-keeping portal (embedded machine, [NPC Classes](NPC%20Classes.md))
  and the decayed time-portal are the same character at different stages of decline — a
  machine whose *memory of where it goes* is failing. Freshest-is-least-complete, inverted.
- **Story geometry this enables:** standing on ruin-era earth while bloom-era earth hangs in
  the sky (sky edges resolve through the registry too — the sky can show another *time*);
  visiting the moon "again" and finding it younger; the Builders' fate witnessable in strata.
- **The sky shows another *place* too (Eddie, 2026-07-11).** Not just the counterpart worlds —
  the **skybox itself** is a registry-resolved view: a world out beyond the rim shows the
  whole galaxy edge-on in its night sky; a world parked near the Orion Nebula glows with it,
  *because that's where the Builders pull raw material from.* The sky becomes the game's
  location (and era) signage — no map UI, you learn to read WHERE and WHEN you are from what
  hangs overhead. Engineering shape: a per-world sky identity (skybox/celestial dressing) in
  the world stamp, resolved through the same key machinery — cheap, since interiors already
  prove the sky pass is per-world. Narrative knife included: a decayed portal that lies about
  its destination is *betrayed by the sky* — the player who has learned to read it can catch
  the lie.

## Open questions

- **Portal-specific keys** — do two doors on the same world leading to the "same" destination ever resolve differently (key = `(destination, origin, portal)`)? Undecided; the key type should leave room.
- Registry **persistence/serialization** once save games exist (every visited key's world carries scars).
- Whether an interior world ever *reports back* to its surface (a quake inside visibly cracks the outside) — expressible later as a scripted link between instances, not shared state.

## Engineering shape (small, clean)

Today: `Renderer.worldStack` + a hardcoded `testInterior` moon. Becomes: a **world registry** — `[(destination, context) : GameState]` — lazy-created, persistent; the stack remains the *navigation history*, the registry is the *universe*. The counterpart (sky) lookup goes through the same registry. M15 builds on this from day one; it also subsumes M11's "multiple portal destinations" remaining item.
