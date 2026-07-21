"""Deterministic equirectangular starfield skybox from the HYG v4.1 catalog.
Real RA/Dec positions; greyscale; magnitude -> brightness (compressed) and size.
Faint stars = single grey pixel; bright stars = white core + soft grey halo,
halo squashed horizontally by 1/cos(dec) near the poles so it stays round on the sphere."""
# Data: HYG v4.1 catalog. Download hyg.csv (~33 MB, not committed) into this dir from:
#   https://raw.githubusercontent.com/astronexus/HYG-Database/main/hyg/CURRENT/hygdata_v41.csv
import csv, math
import numpy as np
from PIL import Image

W, H = 8192, 4096
MAG_CUT   = 8.0      # include down to mag 8 (~naked-eye is 6.5; fainter fills the 8k canvas)
MAG_SPLIT = 3.5      # brighter than this gets a sized halo; fainter is a single pixel
MAG_BRT   = -1.5     # brightest reference (Sirius ~ -1.46)
FLOOR     = 0.16     # dimmest star grey (~40/255)
SINGLE_TOP= 0.72     # grey value of a single-pixel star right at the split
GAMMA     = 0.80     # <1 lifts the faint midtones so dim stars stay visible

img = np.zeros((H, W), dtype=np.float32)

# ---- load stars ----
ra, dec, mag = [], [], []
with open("hyg.csv", newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        try:
            m = float(row["mag"])
        except (ValueError, KeyError):
            continue
        if m > MAG_CUT:
            continue
        try:
            a = float(row["ra"]); d = float(row["dec"])
        except ValueError:
            continue
        ra.append(a); dec.append(d); mag.append(m)
ra = np.array(ra); dec = np.array(dec); mag = np.array(mag)
print(f"stars <= mag {MAG_CUT}: {len(mag)}")

# ---- projection: equirect, dec +90 = top row (north pole) ----
x = (ra / 24.0) * W
y = ((90.0 - dec) / 180.0) * H
xi = np.clip(x.astype(int), 0, W - 1)
yi = np.clip(y.astype(int), 0, H - 1)

# ---- brightness (compressed, linear-in-magnitude with gamma) ----
faint = mag >= MAG_SPLIT
tf = np.clip((MAG_CUT - mag[faint]) / (MAG_CUT - MAG_SPLIT), 0, 1)
val_faint = FLOOR + (SINGLE_TOP - FLOOR) * (tf ** GAMMA)
np.add.at(img, (yi[faint], xi[faint]), val_faint)

# ---- bright stars: white core + pole-squashed grey halo ----
bi = np.where(~faint)[0]
print(f"haloed (mag < {MAG_SPLIT}): {len(bi)}")
for i in bi:
    xc, yc = xi[i], yi[i]
    s = MAG_SPLIT - mag[i]                    # 0..5
    r = min(6.0, 1.5 + s * 1.1)               # halo radius (vertical)
    cd = max(math.cos(math.radians(dec[i])), 0.045)
    rx = min(22.0, r / cd)                     # horizontal radius, squashed near poles (capped)
    ry = r
    sx, sy = max(rx / 2.2, 0.6), max(ry / 2.2, 0.6)
    x0, x1 = int(xc - rx) - 1, int(xc + rx) + 2
    y0, y1 = max(0, int(yc - ry) - 1), min(H, int(yc + ry) + 2)
    for yy in range(y0, y1):
        dy = yy - yc
        for xx in range(x0, x1):
            dx = xx - xc
            g = 0.55 * math.exp(-((dx / sx) ** 2 + (dy / sy) ** 2) * 0.5)
            xw = xx % W                        # longitude wraps at the seam
            if g > img[yy, xw]:
                img[yy, xw] = max(img[yy, xw], g)
    img[yc, xc % W] = 1.0                       # white core
    if r > 3:                                   # 2px core for the brightest
        img[yc, (xc + 1) % W] = max(img[yc, (xc + 1) % W], 0.9)

# ---- write ----
out = (np.clip(img, 0, 1) * 255).astype(np.uint8)
Image.fromarray(out, "L").save("RealStarfield_8k.png")
Image.fromarray(out, "L").resize((2048, 1024), Image.LANCZOS).save("starfield_preview.png")
# a 1:1 crop across the galactic plane region for a detail check
Image.fromarray(out[1750:2050, 3400:4600], "L").save("starfield_crop.png")
print("wrote RealStarfield_8k.png (8192x4096), preview, crop")
print(f"nonzero pixels: {(out>0).sum()}  peak: {out.max()}")
