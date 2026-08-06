# Known Issues (living)

*Small tracked defects that are understood but deliberately not fixed yet. Not a backlog of
features — that's the roadmap. This is "things that are wrong and we've decided to live with,
for now, and why."*

## ~~Imported models load from absolute dev paths (M20)~~ — FIXED 2026-08-06
**Was:** `AssetRegistry` and the skybox loader read `/Volumes/Code Work/…` absolutes, so the game
ran on exactly one computer; anywhere else every imported prop silently failed to load and the app
booted into an undressed world (the loaders degrade to empty, so it looked authored).

**Now:** `ResourcePaths` resolves the bundle first, then the source tree derived from `#filePath` at
compile time — no volume name, no user name. A fresh clone therefore runs in Xcode **on any machine
at any path**, and a built app is self-contained. A build phase copies exactly what `git ls-files`
tracks under `Mazen_Models` and `Skyboxes` into `Resources/`, so "works from a clone" and "works as
a built app" cannot drift apart. `ENABLE_APP_SANDBOX` is back ON for both targets.

*Consequence recorded:* `ENABLE_USER_SCRIPT_SANDBOXING` had to go OFF. Declaring the two folders as
`inputPaths` grants the script the top-level directories only — every subdirectory still came back
"Operation not permitted" — and the manifest step needs to read `.git` as well. That is a
build-time setting; the runtime one that matters (`ENABLE_APP_SANDBOX`) moved the other way.

## Cube-corner traversal glitchiness (M18)
**Symptom:** walking across one of the cube's 8 triple-corner points (where three faces meet)
has a visible hitch/jump. **Cause:** the corner is a geometric singularity — three tangent
frames disagree there, and the curved-inflation normal (M14b) plus the edge-crossing basis
remap have no continuous single answer at a point with no well-defined tangent plane. Same
family as the degenerate-TBN issue the E/W hedge flicker came from. **Status:** accepted
(Eddie, 2026-07-11) — "not sure what we can even do except steer the player away with props
and story." **Design answer, not a code fix:** author natural worlds and levels so the
corners are uninteresting/avoided (landmarks, water, hedges, story routing keep the player off
the eight corners). Revisit only if a level genuinely needs a corner walked; a real fix would
mean a special-cased corner patch (a rounded triangular fillet with its own frame blend).
