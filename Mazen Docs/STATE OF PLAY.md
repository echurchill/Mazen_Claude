# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-07-08. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md).*

## The 60-second catch-up

We built a first-person, twistable **cube-maze prototype**, and over a design conversation it found its game: **The Garden of Worlds** — a cozy, no-grind, Witness-taught archaeology of impossible worlds. The engine is real and working (M8–M13); the *design* is now the north star; the next work is turning the design's core loop into a playable **vertical slice**.

## The game (the north star)

> You're a tiny traveler *inside* a cluster of maze-planets. **Learn** how a world thinks (from the world itself, never told) → **undo an ancient lock** (bandaging) → **twist the world open** (the slice) → **step inside** it (inverted-cube interiors) → find the **engineered truth beneath the natural surface** → which teaches you the next thing.

One deep verb (the twist), no grind (every action reveals something new), no hand-holding. The bold theme candidate: the Builders *learned everything, lost the ability to forget, and dissolved into background noise* — **wisdom is curation, not accumulation** (ties to a memory/selective-forgetting mechanic no one else has). Full detail + art direction + the new mechanisms (inverted cubes, shape-as-meaning, memory-as-key, long tiles) in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md). The minute-to-minute verb is teased out in [Player Journey](Player%20Journey%20—%20A%20Session.md).

## What's built (the engine is real)

- **Cube + procedural hedge maze**, fog/discovery (currently *revealed-all* for testing), sizes 3–9.
- **The twist** — slice rotation rearranges the maze; you ride it; props/walls/structures carried correctly.
- **M9 solar system** — cube sun/moon, orbits, day/night, phases, eclipse, shadows, idle spin.
- **M10** — perceptual scale, 3×3 sub-cell movement, gateways, rooms, procedural props.
- **M12** — imported 3D models (ModelIO), the modular house that **splits Rubik's-style**, decorations that ride slices.
- **M11 (core done)** — world stack, **TARDIS walk-through portals** + fade, a persistent moon world, and **the killer visual**: the real other world hangs in the sky (moon from earth & vice-versa), turning, with your twists baked in.
- **M13 (foundation done)** — bandaging legality rule + unit tests + enforcement wired, **inert until something's bonded**.
- **Tooling** — debug HUD (`H`), twist pacing (`G`/`[`/`]`), world toggle (`O`), headless tests (`Tests/run-tests.sh`, 7060 checks). All debug toggles default OFF.

## Live design questions (the next real work is here, not code)

1. **Can "this lock needs *understanding X*" be legible with no UI?** The exact needle The Witness / Outer Wilds spend their whole budget threading. Hardest craft problem.
2. **Is the "understand" verb deep enough to repeat across worlds** without becoming "find the switches"? Leading candidate: a **Builder glyph/language you slowly learn to *read*** (Chants of Sennaar / Heaven's Vault style) as the deepening verb.
3. Where memory-*editing* / selective-forgetting enters as a verb vs. staying theme.

## Milestone road to a vertical slice (rough)

M14 shape-as-meaning (superellipsoid) → M15 inverted-cube interiors → **M16 the lock→open→enter chain** (the single most important loop) → M17 memory first pass → M18 one small solar system (a few natural worlds) → M19 cozy/feel polish. Details + sequencing in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md).

## Immediate next actions on resume

- Pick up the **design conversation** (the two craft questions above), or start **M14/M16** if we want to move to code.

## Pending / uncommitted right now

- **Nothing pending.** The sky-world distance change (killer-visual counterpart reset from an artificially-close verify-distance back to the moon's natural orbital position/size, `skyWorldOffset`) is **committed** (`13fbd32`) and pushed.
- Build note: the sandbox may block `xcodebuild` — run builds with the sandbox disabled if it recurs (normal local compile).
- Everything is committed and pushed; `main` == `origin/main`. Repo is **private**.
