"""Five fictional base starfields — realistic magnitude distribution (sampled from HYG so it
matches the natural look) but RANDOM positions (not Earth's sky). Each gets its own synthetic
'galactic' density band at a random tilt: denser star concentration, but point-density only (no
smooth glow), so nothing bands. Greyscale, same render pipeline as the HYG starfield. Base layers
for compositing nebulae externally."""
# Data: HYG v4.1 catalog (magnitudes only). Download hyg.csv (~33 MB, not committed) from:
#   https://raw.githubusercontent.com/astronexus/HYG-Database/main/hyg/CURRENT/hygdata_v41.csv
import csv, math
import numpy as np
from PIL import Image

W, H = 8192, 4096
MAG_SPLIT, FLOOR, SINGLE_TOP, GAMMA = 3.5, 0.16, 0.72, 0.80
MAG_CUT = 8.0

# real HYG magnitudes (<= mag 8) — reused for a realistic brightness distribution
mags_pool = []
with open("hyg.csv", newline="") as f:
    for row in csv.DictReader(f):
        try:
            m = float(row["mag"])
        except (ValueError, KeyError):
            continue
        if m <= MAG_CUT:
            mags_pool.append(m)
mags_pool = np.array(mags_pool)
print(f"HYG magnitude pool: {len(mags_pool)} stars")

def render_stars(ra_h, dec_d, mag):
    img = np.zeros((H, W), np.float32)
    xi = np.clip(((ra_h / 24.0) * W).astype(int), 0, W - 1)
    yi = np.clip((((90.0 - dec_d) / 180.0) * H).astype(int), 0, H - 1)
    faint = mag >= MAG_SPLIT
    tf = np.clip((MAG_CUT - mag[faint]) / (MAG_CUT - MAG_SPLIT), 0, 1)
    np.add.at(img, (yi[faint], xi[faint]), FLOOR + (SINGLE_TOP - FLOOR) * (tf ** GAMMA))
    for i in np.where(~faint)[0]:
        xc, yc = xi[i], yi[i]; s = MAG_SPLIT - mag[i]
        r = min(6.0, 1.5 + s * 1.1); cd = max(math.cos(math.radians(dec_d[i])), 0.045)
        rx = min(22.0, r / cd); sx, sy = max(rx / 2.2, 0.6), max(r / 2.2, 0.6)
        for yy in range(max(0, int(yc - r) - 1), min(H, int(yc + r) + 2)):
            for xx in range(int(xc - rx) - 1, int(xc + rx) + 2):
                g = 0.55 * math.exp(-(((xx - xc) / sx) ** 2 + ((yy - yc) / sy) ** 2) * 0.5); xw = xx % W
                if g > img[yy, xw]: img[yy, xw] = g
        img[yc, xc % W] = 1.0
        if r > 3: img[yc, (xc + 1) % W] = max(img[yc, (xc + 1) % W], 0.9)
    return (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)

# per-skybox character: (n_stars, band_fraction, band_sigma_rad)
CONFIG = [
    (46000, 0.55, 0.14),   # 1 — dense, tight bright band
    (33000, 0.35, 0.24),   # 2 — sparser, broad diffuse band
    (50000, 0.60, 0.11),   # 3 — very dense, sharp band
    (38000, 0.45, 0.18),   # 4 — medium
    (30000, 0.30, 0.30),   # 5 — sparse, nearly uniform
]

def unit(rng):
    v = rng.normal(size=3); return v / np.linalg.norm(v)

for idx, (n_stars, band_frac, band_sig) in enumerate(CONFIG, 1):
    rng = np.random.RandomState(1000 + idx)
    mag = rng.choice(mags_pool, size=n_stars)
    nb = int(n_stars * band_frac); nf = n_stars - nb
    # band plane: random pole n, orthonormal u,v
    n = unit(rng); a = np.array([1.0, 0, 0]) if abs(n[0]) < 0.9 else np.array([0, 1.0, 0])
    u = np.cross(n, a); u /= np.linalg.norm(u); v = np.cross(n, u)
    phi = rng.uniform(0, 2 * math.pi, nb); beta = rng.normal(0, band_sig, nb)
    db = (np.cos(beta)[:, None] * (np.cos(phi)[:, None] * u + np.sin(phi)[:, None] * v)
          + np.sin(beta)[:, None] * n)
    z = rng.uniform(-1, 1, nf); th = rng.uniform(0, 2 * math.pi, nf); rr = np.sqrt(1 - z * z)
    dfld = np.stack([rr * np.cos(th), rr * np.sin(th), z], axis=1)
    dirs = np.concatenate([db, dfld], axis=0)
    dec = np.degrees(np.arcsin(np.clip(dirs[:, 2], -1, 1)))
    ra = (np.degrees(np.arctan2(dirs[:, 1], dirs[:, 0])) % 360.0)
    out = render_stars(ra / 15.0, dec, mag)
    Image.fromarray(out).save(f"SynthStarfield_{idx}.png")
    Image.fromarray(out.reshape(H // 4, 4, W // 4, 4).max(axis=(1, 3))).save(f"synth_prev_{idx}.png")
    print(f"skybox {idx}: {n_stars} stars, band {int(band_frac*100)}% -> SynthStarfield_{idx}.png")
print("done")
