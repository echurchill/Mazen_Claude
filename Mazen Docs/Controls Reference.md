# Controls Reference

## macOS — Keyboard & Mouse

| Input | Action |
|---|---|
| W / Up Arrow | Move forward |
| S / Down Arrow | Move backward (turn 180 then step) |
| A / Left Arrow | Turn left |
| D / Right Arrow | Turn right |
| Space | Toggle camera mode (orbit / first-person) |
| Q | Rotate current face slice clockwise |
| E | Rotate current face slice counterclockwise |
| P | Toggle orbit auto-rotation |
| N | Cycle cube size (3 → 4 → 5 → 3) |
| H | Toggle debug HUD (face, position, fps) |
| Mouse drag | Orbit rotation (orbit mode only) |
| Scroll wheel | Orbit zoom in/out (range 5–15, orbit mode only) |

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
- The debug HUD (macOS only) shows current face, grid position, facing direction, camera mode, cube size, and frame timing.
