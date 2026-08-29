# Controls Reference

## macOS — Keyboard & Mouse

### Move & look
| Input | Action |
|---|---|
| W / Up Arrow | Move forward (hold to keep walking) |
| S / Down Arrow | Move backward (hold) |
| A / Left Arrow | Turn left |
| D / Right Arrow | Turn right |
| Space | Toggle camera mode (orbit / first-person) |
| Mouse move (first-person) | Free-look — yaw + pitch (mouselook, always on in FP) |
| Mouse drag (orbit) | Rotate the orbit camera |
| Scroll wheel (orbit) | Zoom in/out |

### Cube & slice
| Input | Action |
|---|---|
| Q | Rotate the current face's slice clockwise |
| E | Rotate the current face's slice counter-clockwise |
| Shift + Q / Shift + E | **Replay the scene's scripted turn** (debug) — turns the slab a scene names for its puzzle payoff (Scene 2's hidden-exit slab), so a one-off reveal can be watched repeatedly. Respects bonds: does nothing while the lock still refuses that slab. Pair with **G** to slow it and **[** / **]** to scrub it frame by frame. |
| G | Cycle slice-twist pacing: **normal → slow (0.15×) → single-step** |
| ] | Scrub a held twist **forward** (single-step pacing) |
| [ | Scrub a held twist **backward** (single-step pacing) |
| B | Fire the synthesised **audio test tone** — proves the PHASE path is alive (engine started, asset registered, mixer reachable) without needing a puzzle to trigger a cue. Silence here means the engine failed to start; silence *only* on a cue means that cue's binding is wrong. |
| N | Cycle cube size (3 → 5 → 7 → 9) |

### World & props
| Input | Action |
|---|---|
| F | Interact with a prop on the current tile (e.g. open/close a chest) |
| T | Cycle time scale (1× → 8× → 60×) |
| Shift + T | Freeze time at high noon (stable, predictable light) |
| P | Toggle orbit auto-rotation |
| H | Toggle debug HUD (face, position, camera, cube size, fps, twist pacing). The **Walls** line reads `NESW` — a letter where the engine believes there is a wall, a dot where it believes there is a way through — plus your stand sub-cell and any SOLID prop on the tile. Use it on an invisible wall: a letter in the direction you are pushing means a wall failed to *draw*; a dot means *collision* is wrong. Those need opposite fixes and look identical otherwise. |

### Debug — worlds & views (macOS)
| Input | Action |
|---|---|
| `` ` `` (grave) | **Portal hub** — the single entry point to every world: a plaza of labeled TARDIS portals (Moon, Temple Interior, Natural, Garden, Gallery, and the four pack galleries). Walk up, read the signpost, step through. Press again to leave. *(This replaced the per-world jump keys O / I / B / V / Y / 1–4.)* |
| U | Make the garden door lock READY (bypass the switches, for testing the turn) |
| M | Toggle flat matte shading (read raw geometry) |
| J | Toggle idle world spin |
| `-` / `=` | Deflate / inflate roundness (all worlds) |
| `,` / `.` | Lower / raise relief (hill amplitude) |

## iOS — Touch Gestures

| Gesture | Action |
|---|---|
| **Tap (standing on something usable)** | **Interact — the touch equivalent of `F`.** Portals, vessels, anchors, switches, plinths, dials, chests and Scene 5's rotators. Until 2026-08-03 touch had no way to reach `interact()` at all, so every control in the prologue was keyboard-only. |
| Tap (anywhere else) | Move forward (first-person mode only) |
| Double-tap | Toggle camera mode (orbit / first-person) |
| Swipe up | Move forward (first-person mode) |
| Swipe down | Move backward (first-person mode) |
| Swipe left | Turn left (first-person mode) |
| Swipe right | Turn right (first-person mode) |
| Pan drag | Orbit rotation (orbit mode) |
| Two-finger swipe right | Rotate face slice clockwise (first-person mode) |
| Two-finger swipe left | Rotate face slice counterclockwise (first-person mode) |
| Pinch | Orbit zoom in/out (range 3–15, orbit mode only) |

## Scene 5 — rotators instead of keys

Scene 5 carries **six rotator controls, one near the middle of each face**. Each turns **the slab it
stands on** — the outer layer of the face under your feet, the same slab `Q`/`E` would turn from
there — one quarter turn per use, always the same way round (so three uses reverse one). They are
placed off the channels and off the source, receivers and vessels, and they are stamped *after* the
scramble so "off the circuit" is true of the world you actually walk.

They exist because `Q`/`E` cannot be pressed on a phone, and the scene is now solvable using nothing
but walking and pressing — asserted by `testSceneFiveCanBeSolvedByItsRotatorsAlone`, which never
touches the keyboard verb.

## Notes

- **The app boots into the first world** (M20): a pastoral home clearing whose stone arch leads to
  the garden. The old demo hub is retired as the boot world; the debug world keys above still jump
  anywhere.
- **Walk-through portals** fire when you step onto the portal itself — its centre sub-cell — not
  merely anywhere on its tile. A portal you spawn on (or that a twist rotates under you) stays
  inert until you walk off and back on. `F` on the tile also works.
- Movement and turning animate smoothly; inputs queue if pressed during an animation.
- Slice rotation is only available when the player is stationary (not moving or turning).
- Orbit auto-rotation pauses when you manually drag or pan the camera.
- The debug HUD (macOS only) shows current face, grid position, facing direction, camera mode, cube size, frame timing, and the current twist pacing.
- **Twist pacing (G / `[` / `]`)** is a diagnostic aid for inspecting how a slice carries geometry — e.g. watching the imported modular house split at its tile seams. In **single-step** pacing a Q/E twist starts frozen; `]` inches it forward a notch and `[` walks it back. It finalizes on reaching the end, and can be scrubbed back toward the start to re-check. Set it back to **normal** with G for regular play.

## Portal-view capture (debug)

| key | what it does |
|---|---|
| `'` | **Arms** the portal-view capture. Nothing happens yet — the window title says it is armed. |
| `;` | **Mute / unmute everything.** |

The shot is taken **by itself, on the next portal arrival** — after the fade completes and the world
has settled — and written to `PortalViews/<destination>--from--<origin>.png`. That file is then what
that door shows, in every world that leads there by that route: doors display the view you will
actually have when you step through, with a parallax shift so they read as windows rather than
posters. A door with no capture keeps its procedural vortex.

Captures need the **Debug** configuration (Release is sandboxed and cannot write into the repo).

---

## Gamepad (macOS and iPadOS, 2026-08-07)

Any MFi / Xbox / PlayStation controller. Same file, same mapping, both platforms — `GCController` is
one API and this game's whole input surface is about eight calls.

| control | does |
|---|---|
| **Left stick / D-pad** ↑↓ | walk forward / back (held, chains hops like `W`/`S`) |
| **Left stick / D-pad** ←→ | turn, in discrete 45° steps with a repeat while held |
| **Right stick** | first-person look; orbit rotation in orbit mode |
| **A** | interact (`F`) |
| **Y** | toggle first-person / orbit |
| **Menu** | the portal hub (`` ` ``) — the single entry point to every world |
| **L1 / R1** | twist the slice counter-clockwise / clockwise (`Q` / `E`) |

**Why the shoulders for the twist:** it is the world moving, not the player reaching for something
in front of them — and L/R reads as "that way round". It also gives the iPad two real buttons for
the one verb touch cannot teach. That is a stopgap, not the answer: Scene 4 still wants a walk-up
control the way Scene 5's rotators work.

**Two numbers to tune by feel:** `turnRepeat` (0.22 s between steps while the stick is held) and
`lookRate` (2.6 rad/s at full deflection). Both in `GamepadInput.swift`.

*Keyboard and pad share `forwardHeld`/`backwardHeld`. The pad only writes them while a stick or
d-pad is actually pushed, and clears them once on release — otherwise a controller merely PAIRED,
sitting untouched on a desk, sets them false every frame and W/S stop working entirely. That was a
real regression; `MAZEN_INPUT_SELFTEST=1` now checks it at boot and says REGRESSION out loud.*

*macOS Release is sandboxed, so a wireless pad needs `com.apple.security.device.bluetooth` — set via
`ENABLE_RESOURCE_ACCESS_BLUETOOTH`. Without it the controller is never seen at all, and the
`[gamepad] active:` line at boot is how you know it was.*

## The turnable slab (experimental, 2026-08-07)

Wherever the player *can* twist (`twistEnabled` — the prologue withholds it until Scene 4), the floor
of the slab a twist would turn **breathes**: a slow brighten-and-cool, about one cycle every four
seconds, suppressed while a twist is already running.

It exists because `startSliceRotation` turns the slice under your feet and nothing ever said which
one that was. On a keyboard you learn it; with a controller on a couch you cannot (Eddie's first iPad
run). This makes the verb a place you are standing rather than a key you know — and it is the cue
Scene 4 needs regardless of input, since that scene's whole job is to teach the twist.

Not the final answer: the walk-up rotator props (Scene 5's pattern) are still what the scenes want.
This is the cheap version that works for keyboard, controller and touch at once.

## Teaching prompts (2026-08-07)

Title-card text, low and centred, in the game's own voice rather than dressed as part of the world.
Each one **stays until the player does the thing** — no timers, nobody stuck — and the wording
follows whatever is in their hands, switching if they put the keyboard down and pick up a pad.

| moment | says | goes away when |
|---|---|---|
| attract | *press anything to begin* | any key, button, stick or tap |
| Scene 1, on landing | *left stick to walk* / *W and S to walk* | they actually move |
| Scene 1, out of the clearing | *right stick to look around* / *move the mouse…* | they actually look |
| Scene 2, on the first thing worth pressing | *A to use it* / *F to use it* | they actually use something |

The last is armed only once the player has come **through a portal**, which is Scene 2 by
definition — Scene 1's vessels are scenery that rewards curiosity, not the game's first instruction.
Nothing teaches portals: walking through a door teaches itself.

Benchmarks skip prompts; `MAZEN_PROMPTS=1` forces them on.
