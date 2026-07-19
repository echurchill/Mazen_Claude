# Known Issues (living)

*Small tracked defects that are understood but deliberately not fixed yet. Not a backlog of
features — that's the roadmap. This is "things that are wrong and we've decided to live with,
for now, and why."*

## Imported models load from absolute dev paths (M20)
**Symptom:** none today — everything works on the dev machine. **Cause:** `AssetRegistry.loadAll`
(and the MegaKit texture resolution) read `Mazen_Models` from the absolute path
`/Volumes/Code Work/xCode work/Mazen_Claude/Mazen_Models` — the models are NOT in the app bundle.
On any other machine (or a notarized build) every imported prop silently fails to load: portal
frames, dressed walls, garden vegetation all vanish (the app still boots — loaders degrade to
empty). **Status:** flagged (Fable, 2026-07-19) — fine for the prototype, a hard blocker for
shipping/sharing builds. **Fix when it matters:** copy the used subset of `Mazen_Models` into the
bundle (a build phase) and point `modelsRoot` at `Bundle.main`, keeping the dev-path fallback.

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
