#!/usr/bin/env python3
"""Notch app icon — "Obsidian Signal".

Dark glass squircle, notch pill with camera, emissive status bars (cyan + one amber),
floor reflections, grazing edge light, micro-grain. Rendered at 4096 and downsampled.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

S = 4096                      # supersample canvas
T = 0.8047 * S                # Apple grid: tile is ~824/1024 of canvas
O = (S - T) / 2               # tile origin (margin)
CX = S / 2

Y, X = np.mgrid[0:S, 0:S].astype(np.float32)


def squircle(cx, cy, w, h, r, n=2.6):
    """Anti-aliased mask of a rounded rect with superelliptical (continuous) corners."""
    dx = np.clip(np.abs(X - cx) - (w / 2 - r), 0, None)
    dy = np.clip(np.abs(Y - cy) - (h / 2 - r), 0, None)
    rho = ((dx / r) ** n + (dy / r) ** n) ** (1.0 / n)
    return np.clip((1 - rho) * r + 0.5, 0, 1)


def capsule(cx, cy, w, h):
    r = min(w, h) / 2 * 0.999
    return squircle(cx, cy, w, h, r, n=2.02)


def circle(cx, cy, rad):
    d = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2)
    return np.clip(rad - d + 0.5, 0, 1)


def vgrad(y0, y1, stops):
    """Vertical gradient. stops: [(t, (r,g,b)), ...], colors 0-255."""
    t = np.clip((Y - y0) / (y1 - y0), 0, 1)
    ts = np.array([s[0] for s in stops], np.float32)
    cols = np.array([s[1] for s in stops], np.float32) / 255.0
    return np.stack([np.interp(t, ts, cols[:, i]) for i in range(3)], axis=-1)


def radial(cx, cy, rad):
    """1 at center -> 0 at rad, smooth."""
    d = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2) / rad
    return np.clip(1 - d, 0, 1) ** 2


def blur(arr, radius):
    """Gaussian blur a float 2D array (0..1)."""
    im = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8))
    return np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255.0


def over(dst, rgb, a):
    """Composite premultiplied dst under straight (rgb, a) source."""
    a3 = a[..., None]
    dst[..., :3] = rgb * a3 + dst[..., :3] * (1 - a3)
    dst[..., 3] = a + dst[..., 3] * (1 - a)


def add_light(dst, rgb, a):
    """Additive light, only where dst has coverage."""
    dst[..., :3] = np.clip(dst[..., :3] + rgb * a[..., None], 0, 4)


C = lambda *v: np.array(v, np.float32) / 255.0

# ---------------------------------------------------------------- canvas
img = np.zeros((S, S, 4), np.float32)

tile = squircle(CX, S / 2, T, T, 0.2237 * T)

# Drop shadows: ambient + contact
sh_soft = blur(np.roll(tile, int(0.016 * S), axis=0), 0.030 * S)
sh_tight = blur(np.roll(tile, int(0.006 * S), axis=0), 0.010 * S)
over(img, C(0, 0, 0), sh_soft * 0.34)
over(img, C(0, 0, 0), sh_tight * 0.22)

# ---------------------------------------------------------------- glass slab
base = vgrad(O, O + T, [
    (0.00, (68, 74, 89)),
    (0.42, (34, 37, 47)),
    (1.00, (13, 15, 20)),
])
over(img, base, tile)

# top key light + corner vignette
add_light(img, C(190, 205, 235), radial(CX, O + 0.02 * T, 0.85 * T) * tile * 0.055)
vig = (1 - radial(CX, S / 2, 1.05 * T)) * tile
img[..., :3] *= (1 - 0.13 * vig[..., None])

# ambient cyan rising from behind the bars
add_light(img, C(34, 170, 220), radial(CX, O + 1.02 * T, 0.78 * T) * tile * 0.11)

# ---------------------------------------------------------------- notch pill
pw, ph = 0.400 * T, 0.088 * T
pcy = O + 0.085 * T + ph / 2
pill = capsule(CX, pcy, pw, ph)
over(img, C(4, 5, 7), pill)
# light catching the pill's bottom edge
pill_rim = np.clip(pill - np.roll(pill, -int(0.0022 * T), axis=0), 0, 1)
add_light(img, C(150, 165, 195), blur(pill_rim, 0.0012 * T) * 0.16)
# camera: lens + iris + glint
dot_r = 0.0165 * T
over(img, C(24, 27, 34), circle(CX, pcy, dot_r))
over(img, C(52, 78, 110), circle(CX, pcy, dot_r * 0.60) * 0.9)
add_light(img, C(140, 200, 255), circle(CX - dot_r * 0.28, pcy - dot_r * 0.30, dot_r * 0.22) * 0.5)

# ---------------------------------------------------------------- status bars
bw, gap = 0.088 * T, 0.068 * T
heights = [0.155, 0.295, 0.215, 0.415]
amber_i = 2
group_w = 4 * bw + 3 * gap
x0 = CX - group_w / 2 + bw / 2
base_y = O + 0.82 * T

CYAN = dict(top=(172, 240, 255), bot=(26, 178, 226), glow=(63, 214, 255))
AMBER = dict(top=(255, 214, 150), bot=(242, 148, 34), glow=(255, 180, 67))

emissive = np.zeros((S, S, 3), np.float32)   # for the bloom pass
for i, hf in enumerate(heights):
    col = AMBER if i == amber_i else CYAN
    h = hf * T
    bx = x0 + i * (bw + gap)
    bcy = base_y - h / 2
    m = capsule(bx, bcy, bw, h)

    g = vgrad(base_y - h, base_y, [(0.0, col["top"]), (0.55, col["bot"]),
                                   (1.0, tuple(int(c * 0.82) for c in col["bot"]))])
    over(img, g, m)
    # hot core near the top cap — makes the bar read as emissive, not painted
    core = capsule(bx, base_y - h + bw * 0.52, bw * 0.44, min(h * 0.5, bw * 1.6))
    add_light(img, C(255, 255, 255), blur(core, bw * 0.18) * 0.34)

    emissive += np.array(col["glow"], np.float32)[None, None] / 255.0 * m[..., None]

    # reflection on the glass floor — a faint emissive smear, not a mirrored body
    refl = np.flipud(np.roll(m, -int(2 * (S / 2 - base_y) - 0.014 * T), axis=0))
    fade = np.clip(1 - (Y - base_y - 0.014 * T) / (0.11 * T), 0, 1) ** 2.5
    refl = blur(refl, 0.004 * T) * fade * (Y > base_y)
    add_light(img, np.array(col["glow"], np.float32) / 255.0, refl * tile * 0.13)

# bloom: wide halo + tight glow, confined inside the glass
for rad, k in ((0.040 * S, 0.34), (0.011 * S, 0.30)):
    bl = np.stack([blur(emissive[..., i], rad) for i in range(3)], axis=-1)
    img[..., :3] = np.clip(img[..., :3] + bl * tile[..., None] * k, 0, 4)

# ---------------------------------------------------------------- glass finish
# grazing highlight on the top edge
ring = np.clip(tile - squircle(CX, S / 2, T - 0.010 * T, T - 0.010 * T, 0.2237 * (T - 0.010 * T)), 0, 1)
topw = np.clip(1 - (Y - O) / (0.32 * T), 0, 1) ** 1.5
add_light(img, C(225, 235, 255), blur(ring * topw, 0.0011 * T) * 0.55)
# faint rim on the sides / bottom so the slab reads as glass all round
add_light(img, C(140, 160, 200), blur(ring, 0.0011 * T) * 0.10)
# soft sheen falling from the top, biased to the light side
sheen = np.clip(1 - (Y - O) / (0.26 * T), 0, 1) ** 2 * tile
sheen *= 1 + 0.5 * np.clip(1 - (X - O) / (0.9 * T), 0, 1)
add_light(img, C(255, 255, 255), sheen * 0.042)
# inner shadow settling at the bottom
ring2 = np.clip(tile - squircle(CX, S / 2, T - 0.030 * T, T - 0.030 * T, 0.2237 * (T - 0.030 * T)), 0, 1)
botw = np.clip((Y - (O + 0.60 * T)) / (0.40 * T), 0, 1)
dark = blur(ring2 * botw, 0.004 * T) * 0.30
img[..., :3] *= (1 - dark[..., None])

# ---------------------------------------------------------------- output
img[..., :3] = np.clip(img[..., :3], 0, 1)
a = np.clip(img[..., 3:4], 1e-4, 1)
straight = np.concatenate([img[..., :3] / a * (a > 1e-3), img[..., 3:4]], axis=-1)
out = Image.fromarray((np.clip(straight, 0, 1) * 255).astype(np.uint8), "RGBA")

master = out.resize((1024, 1024), Image.LANCZOS)

# micro-grain so the glass doesn't look computer-clean (applied at final scale)
m = np.asarray(master, np.float32)
tile1024 = np.asarray(Image.fromarray((tile * 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS), np.float32) / 255.0
rng = np.random.default_rng(7)
noise = rng.normal(0, 2.0, (1024, 1024, 1)).astype(np.float32)
m[..., :3] = np.clip(m[..., :3] + noise * tile1024[..., None], 0, 255)
master = Image.fromarray(m.astype(np.uint8), "RGBA")

outdir = sys.argv[1] if len(sys.argv) > 1 else "."
master.save(f"{outdir}/master-1024.png")
print("saved", f"{outdir}/master-1024.png")
