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

## Open questions

- **Portal-specific keys** — do two doors on the same world leading to the "same" destination ever resolve differently (key = `(destination, origin, portal)`)? Undecided; the key type should leave room.
- Registry **persistence/serialization** once save games exist (every visited key's world carries scars).
- Whether an interior world ever *reports back* to its surface (a quake inside visibly cracks the outside) — expressible later as a scripted link between instances, not shared state.

## Engineering shape (small, clean)

Today: `Renderer.worldStack` + a hardcoded `testInterior` moon. Becomes: a **world registry** — `[(destination, context) : GameState]` — lazy-created, persistent; the stack remains the *navigation history*, the registry is the *universe*. The counterpart (sky) lookup goes through the same registry. M15 builds on this from day one; it also subsumes M11's "multiple portal destinations" remaining item.
