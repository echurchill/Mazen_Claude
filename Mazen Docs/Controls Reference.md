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
| G | Cycle slice-twist pacing: **normal → slow (0.15×) → single-step** |
| ] | Scrub a held twist **forward** (single-step pacing) |
| [ | Scrub a held twist **backward** (single-step pacing) |
| N | Cycle cube size (3 → 5 → 7 → 9) |

### World & props
| Input | Action |
|---|---|
| F | Interact with a prop on the current tile (e.g. open/close a chest) |
| T | Cycle time scale (1× → 8× → 60×) |
| Shift + T | Freeze time at high noon (stable, predictable light) |
| P | Toggle orbit auto-rotation |
| H | Toggle debug HUD (face, position, camera, cube size, fps, twist pacing) |

### Debug — worlds & views (macOS)
Each fades into / out of a separate world (press again to return).
| Input | Action |
|---|---|
| O | Temple/interior inverted-cube world |
| I | Temple-interior world |
| B | Natural open-field world |
| V | Garden (natural-maze hybrid, the Journey entry world) |
| Y | Prop/foliage gallery (Quaternius Stylized Nature) |
| 1 | Dungeons pack evaluation gallery (full-face grid) |
| 2 | Nature pack evaluation gallery (full-face grid) |
| 3 | Ruins pack evaluation gallery (full-face grid) |
| U | Make the garden door lock READY (bypass the switches, for testing the turn) |
| M | Toggle flat matte shading (read raw geometry) |
| J | Toggle idle world spin |
| `-` / `=` | Deflate / inflate roundness (all worlds) |
| `,` / `.` | Lower / raise relief (hill amplitude) |

## iOS — Touch Gestures

| Gesture | Action |
|---|---|
| Tap | Move forward (first-person mode only) |
| Double-tap | Toggle camera mode (orbit / first-person) |
| Swipe up | Move forward (first-person mode) |
| Swipe down | Move backward (first-person mode) |
| Swipe left | Turn left (first-person mode) |
| Swipe right | Turn right (first-person mode) |
| Pan drag | Orbit rotation (orbit mode) |
| Two-finger swipe right | Rotate face slice clockwise (first-person mode) |
| Two-finger swipe left | Rotate face slice counterclockwise (first-person mode) |
| Pinch | Orbit zoom in/out (range 3–15, orbit mode only) |

## Notes

- Movement and turning animate smoothly; inputs queue if pressed during an animation.
- Slice rotation is only available when the player is stationary (not moving or turning).
- Orbit auto-rotation pauses when you manually drag or pan the camera.
- The debug HUD (macOS only) shows current face, grid position, facing direction, camera mode, cube size, frame timing, and the current twist pacing.
- **Twist pacing (G / `[` / `]`)** is a diagnostic aid for inspecting how a slice carries geometry — e.g. watching the imported modular house split at its tile seams. In **single-step** pacing a Q/E twist starts frozen; `]` inches it forward a notch and `[` walks it back. It finalizes on reaching the end, and can be scrubbed back toward the start to re-check. Set it back to **normal** with G for regular play.
