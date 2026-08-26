# Tools

Small one-off generators kept in the repo so the things they make can be re-made.

## MakeIcon.swift — the app icon

Draws the maze planet from the attract screen: a real maze (depth-first backtracker, lightly
braided so it has loops), rendered flat and then mapped onto a disc with a radial expansion that
mimics an orthographic sphere, lit from the upper right to match the low sun of Scene 1.

```bash
swiftc -O Tools/MakeIcon.swift -o /tmp/makeicon && /tmp/makeicon /tmp/icons
```

It writes `icon-{16,32,64,128,256,512,1024}.png` plus dark and tinted 1024s, which are what
`Mazen_Claude Shared/Assets.xcassets/AppIcon.appiconset` references. Re-run it and re-copy if the
look ever needs to change — the icon is code, not an artefact somebody has to find the source file
for.
