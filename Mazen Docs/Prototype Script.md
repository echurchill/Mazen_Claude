# Prototype Worlds…

*The buildable production spec — the "level bible" for the vertical slice: one entry per world, grouped by solar system. **This is the target, not a description of the current build** (which differs — see [STATE OF PLAY](STATE%20OF%20PLAY.md)).*

**How this relates to the other docs** (so they don't drift into overlap):
- [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) — the *why* (north star).
- [Player Journey](Player%20Journey%20—%20A%20Session.md) — one *felt* session in prose (a probe).
- [World Graph](World%20Graph%20—%20Relational%20Worlds.md) — the *topology / identity* rules (route-keyed; the sky can lie).
- [Worlds & Portals Plan](Worlds%20and%20Portals%20Plan.md) — the portal *mechanism* (bigger-on-the-inside, world stack).
- [M20 Journey Shot List](M20%20Journey%20Shot%20List.md) — the garden's *tile-level* staging (a detailed appendix to this doc's Garden entry).
- **This doc** — the *authoritative per-world spec* the others feed into.

* Earth-Home
    * Earth-Moon
    * Earth-Sun
* Garden-Home
    * Garden-Temple
    * Garden-Sun

# Prototyle Start World & Location...
Earth-Home @Glade

---

# Conventions

- **`@tags` are stable IDs.** `@World`, `@Location`, and `@Portal` names are globally-unique handles that map 1:1 to code — a world → a `WorldStamp` case, a portal → a `portalDestinations` index. **Namespace portal ids** so they're unique across worlds (e.g. `@EarthHome→GardenHome`, not a `@Portal1` reused in every world). Rename freely — just rename everywhere.
- **This doc is the target.** Each world's **Status** line says how far the build is from the spec; the code's *current* state lives in [STATE OF PLAY](STATE%20OF%20PLAY.md), not here.
- **Shape is meaning** (Design Synthesis). Choose each world's **size** and **roundness** on purpose: *rounder + larger reads as natural / grown; more cubic (lower roundness) + smaller reads as engineered / made.* Note the intended reading in the world's **Visual**.
- Record design **decisions** here (in the relevant **Puzzle / Teaches**); keep the reasoning and rejected options in [Open Questions](Open%20Questions%20%26%20Future%20Work.md).

---

# Per-world template

*Copy this block per world. Drop sections that genuinely don't apply (a sky-only world has no Puzzle); keep the headers you fill. The existing worlds below predate this template — migrate them when convenient.*

## World: @WorldName   *(solar system: …)*

**Status:** *(target / partially built / built — one line)*
**Teaches:** *(what the player LEARNS here — from the world, never told; the Witness beat. The point of the world. "none / pure travel" is a valid answer.)*

### Locations
* @Location — *(one line)*

### Visual
* *(size ×, roundness, terrain, dressing — and the intended shape-as-meaning reading)*

### Sky
* *(what hangs overhead — counterpart world(s), sun/moon — and whether it tells the TRUTH or lies, per World Graph)*

### Puzzle / Lock
* **Goal:** *(the state that opens the gate)*
* **Mechanic:** *(the verb(s); how the player acts)*
* **The key = understanding:** *(what the player must have figured out — not an item — that makes the action work)*
* **Fail / recover:** *(what a wrong or partial state does; is it reversible?)*
* **Legibility:** *(how the player reads progress + goal with no UI)*

### Portals
* @PortalId — **From** @World → **To** @World
    * **Direction:** *(one-way / two-way)*
    * **Gate:** *(none — always open / requires <Puzzle> solved / knowledge-gated on <thing>)*
    * **Style:** *(arch / elevator / veil / none — see the built portal styles)*
    * **Lands at:** *(@Location + facing on the far side)*

### Mood / Audio
* *(placeholder — tone, light, sound; fill in the feel pass)*

### Scene
* *(the screenplay: what the player does, moment to moment. Parenthetical margin-notes for design intent encouraged — the format you already use.)*

### Notes / open
* *(loose ends, questions this world raises)*

---

## World: Earth-Home

### Locations:
* @Glade
* @Maze

### Visual:
* Earth (Earth-Home) is large (25x) and round as possible. 
* We will never visit the other sides of this world. 
* The side the player is on will have a @Glade made of earth native grass, rocks and shrubbery like on our actual earth. 
* The @glade is surrounded by an inescapable hedge wall with many embedded trees lightly.
* The @glade’s open space filled with a light fog nearby but gets thicker farther away. 
* Once a tile has been explored the fog lifts for it. 
* On the far end of the glad is the beginnings of the @Maze (a path made of the same hedge and trees). 
* The @Maze is foggy like the @Glade with a similar lifting effect. 
* The @glade and @maze should constructed keep to the player away from the corner and edge distortions. 
* The @maze has many dead ends, center of each is a vase, ideally with a few destroyed due to the vagaries of time. 
* The vases should be created by the caustic message generator. 
* At this moment the messages are not explained and can simply be random for now, we will come back to make vases’ messages mean something (likely a background story about the builder).
* Earth-Home is orbited by the Moon (Earth-Moon) and visually orbits the Sun (Earth-Sun). 
* The Moon and Sun are visually about the same size and distance from Earth as their natural counter parts. 
* The surface terrain of the Moon is as similar possible to our natural moon. 
* The Sun is yellow. We will never visit either.

### Portals: 
* @Portal1: From (Earth-Home) to (Garden-Home)
    * no puzzle required
    * always open
    * one way

### Scene:
* The story starts with our player waking up in the center of a @Glade. 
* (The player is not given any clues as to what is going on.)
* Eventually the player finds the @maze and starts making their way through it. 
* (The vases are not explained)
* Ultimate the player finds @Portal1 and enters it
* (This is a one-way portal, and the player will never return to Earth-Home)

## World: Earth-Moon

### Locations:
* None

### Visual:
* Earth-Moon orbited by the Moon (Earth-Moon) and visually orbits the Sun (Earth-Sun). 
* The Moon is the same size and distance from Earth as their natural counter parts. 
* The surface terrain of the Moon is as similar possible to our natural moon. 
* 
### Portals: 
* None

### Scene:
* None

## World: Earth-Sun

### Locations:
* None

### Visual:
* The Sun is yellow.
* The Earth-Home visually orbits the Sun
* The Sun is visually farther away from the Earth
* The Sun is the same size and distance from Earth as their natural counter parts. 

### Portals: 
* None

### Scene:
* None

## World: Garden-Home

### Locations:
* @RuinMaze
* @TempleMaze

### Visual: 
* Garden is smaller than (11x) and roundness set to 0.33.
* We will never visit the other sides of this world. 
* The @ruins should keep the player away from the outer most tiles of the side
* (more to be written)

### Portals
* @Portal1: From (Earth-Home) to (Garden-Home)
    * no visualization
    * incoming one way
    * leaves the player near middle of @RuinMaze
* @Portal2: From (Garden-Home) to (Garden-Temple)

##