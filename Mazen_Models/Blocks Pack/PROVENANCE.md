# Blocks Pack — provenance

**Quaternius, "Cube World Kit"** — <https://quaternius.com/packs/cubeworldkit.html>
(identified by Eddie, 2026-08-05).

**Licence: CC0** — stated on that page, confirmed by Eddie (2026-08-05). Same terms as every
other Quaternius pack in `Mazen_Models/`; the others each ship a `License.txt`, and this download
simply arrived without one. That missing file, not the terms, is why the pack sat gitignored while
the others were committed — putting an asset in git redistributes it, and git history does not
forget, so an unlicensed model was the one thing not to wave through on the assumption that it was
probably fine.

This note is the record of that check. If a real licence file ever ships with the pack, drop it in
beside this one.

## What is tracked

`OBJ/` (the curated Blocks + Environment subset the loader reads) and `Textures/` (`Atlas.png`).
The pack's characters, enemies, animals, tools and Pixel Blocks variants stay on disk, unloaded —
no creatures, no combat, no inventory — as do the .blend/FBX/glTF duplicates.

## What uses it

`Blocks Crystal_Big` is Scene 5's surveyor — the roaming machine that grows fractal filigree off
the channels. Nothing else in the game references the pack.
