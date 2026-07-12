# Known Issues (living)

*Small tracked defects that are understood but deliberately not fixed yet. Not a backlog of
features — that's the roadmap. This is "things that are wrong and we've decided to live with,
for now, and why."*

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
