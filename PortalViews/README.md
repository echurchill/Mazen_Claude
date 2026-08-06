# PortalViews

What a door SHOWS. One PNG per route, named `<destination>--from--<origin>.png`
(a bare `<destination>.png` is the fallback for "however you arrived").

Drop a file in, and every door leading there by that route stops showing the procedural vortex and
shows the picture instead, with a parallax shift so it reads as a window rather than a poster. No
file means the old vortex — a missing capture is never a hole in a wall.

## Taking one

Press `'` in a Debug build to **arm** the capture, then walk through a portal. The shot is taken by
itself on arrival, once the fade has finished and the world has settled, and lands here already
named for the route you just took. That is deliberate: the view that belongs in a door is the one
you get standing where the door puts you, and hand-framing it from a screenshot never quite matches.

Release builds are sandboxed and cannot write here. Images of any shape work — they are centre-
cropped square and scaled to 1024² at load, since a texture array needs one size for every slice.

## A note on what these are

A capture is a MOMENT. Twist a world after photographing it and its door will show the place as it
was, not as it is. In a game whose sixth scene is "worlds remember what was done to them", that is
the right kind of wrong — a door shows you the world as you last knew it.
