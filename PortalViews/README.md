# PortalViews

What a door SHOWS. One PNG per route, named `<destination>--from--<origin>.png`
(a bare `<destination>.png` is the fallback for "however you arrived").

Drop a file in, and every door leading there by that route stops showing the procedural vortex and
shows the picture instead, with a parallax shift so it reads as a window rather than a poster. No
file means the old vortex — a missing capture is never a hole in a wall.

## Where files go

Captures are **read** from the app bundle when there is one, and always **written** to this folder
in the repo. Those are different paths, and conflating them is what made the first two captures
vanish: the copy phase had started shipping `PortalViews/` inside the app, so the writes landed in
DerivedData and this folder stayed empty. `ResourcePaths` logs both paths at boot.

## Taking one

Press `'` in a Debug build to **arm** the capture — the window title changes to say so — then walk
through a portal. The shot is taken by
itself on arrival, once the fade has finished and the world has settled, and lands here already
named for the route you just took. That is deliberate: the view that belongs in a door is the one
you get standing where the door puts you, and hand-framing it from a screenshot never quite matches.

Release builds are sandboxed and cannot write here. Images of any shape work — they are centre-
cropped square and scaled to 1024² at load, since a texture array needs one size for every slice.

## A note on what these are

A capture is a MOMENT. Twist a world after photographing it and its door will show the place as it
was, not as it is. In a game whose sixth scene is "worlds remember what was done to them", that is
the right kind of wrong — a door shows you the world as you last knew it.

## Coverage (checked 2026-08-06)

Every portal on the prologue's critical path has a view, except one:

| route | file | |
|---|---|---|
| Scene 1 → Scene 2 | `scene-2--from--scene-1` | ✅ |
| Scene 2 → Scene 3 | `scene-3--from--scene-2` | ✅ |
| Scene 3 → Scene 4 | `scene-4--from--scene-3` | ✅ |
| Scene 4 → Scene 5 | `scene-5--from--scene-4` | ✅ |
| Scene 5 → Scene 6 | `scene-2--from--scene-5` | ✅ (Scene 6 *is* Scene 2, entered from Scene 5) |
| Scene 6 → Scene 3 | `scene-3--from--scene-6` | ✅ (the second descent) |
| Scene 6 → the hub | `portal-hub--from--scene-6` | ❌ **missing** |

That last one is Scene 6's route-keyed exit (`createRouteKeyedExit(destinationID: 9)`) — the
"pseudo scene 7" at the end of the prologue. One arm-and-walk with `'` fills it.

The hub's own doors and the gallery worlds have no captures and need none: they are dev doors, and
without a view they simply keep the swirl.
