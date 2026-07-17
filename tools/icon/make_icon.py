"""R3DIris app icon generator — graphite squircle, six iris blades (teal->violet cyclic gradient), Lambertian gray sphere. 4x supersampled. Writes icon_{16..1024}.png; copy into R3DIris/Assets.xcassets/AppIcon.appiconset/. Requires numpy + pillow."""
import math, os
import numpy as np
from PIL import Image, ImageDraw

S = 4096
CX = CY = S / 2
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# plate
plate = S * 832 // 1024
p0 = (S - plate) // 2
rad = int(plate * 0.225)
grad = np.zeros((plate, plate, 4), dtype=np.uint8)
top = np.array([27, 28, 34]); bot = np.array([13, 14, 16])
for y in range(plate):
    t = y / plate
    grad[y, :, :3] = (top * (1 - t) + bot * t).astype(np.uint8)
    grad[y, :, 3] = 255
plate_img = Image.fromarray(grad, "RGBA")
mask = Image.new("L", (plate, plate), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, plate - 1, plate - 1], radius=rad, fill=255)
img.paste(plate_img, (p0, p0), mask)

# glow
gd = np.zeros((S, S, 4), dtype=np.float32)
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
gr = np.hypot(xx - S * 0.34, yy - S * 0.30) / (S * 0.6)
gd[..., 0] = 63; gd[..., 1] = 216; gd[..., 2] = 199
gd[..., 3] = np.clip(1 - gr, 0, 1) ** 2 * 40
glow = Image.fromarray(gd.astype(np.uint8), "RGBA")
full_mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(full_mask).rounded_rectangle([p0, p0, p0 + plate - 1, p0 + plate - 1], radius=rad, fill=255)
gm = Image.new("RGBA", (S, S), (0, 0, 0, 0)); gm.paste(glow, (0, 0), full_mask)
img = Image.alpha_composite(img, gm)
d = ImageDraw.Draw(img)

teal = np.array([63, 216, 199]); violet = np.array([143, 123, 255])
def ring_color(deg):
    t = (1 - math.cos(math.radians(deg))) / 2   # cyclic teal->violet->teal
    return tuple((teal * (1 - t) + violet * t).astype(int)) + (255,)

R = plate * 0.335
W = plate * 0.060
SWEEP, GAP = 47, 13
STEP = 1.0
for i in range(6):
    a0 = i * (SWEEP + GAP) - 90 + GAP / 2
    # segmented arc with smooth cyclic gradient
    a = a0
    while a < a0 + SWEEP:
        col = ring_color(a + STEP / 2)
        d.arc([CX - R, CY - R, CX + R, CY + R], start=a, end=min(a + STEP * 1.6, a0 + SWEEP), fill=col, width=int(W))
        a += STEP
    # rounded caps, same radius as half stroke
    Rc = R - W / 2   # PIL arc strokes inward from the bbox — caps sit mid-stroke
    for ang in (a0, a0 + SWEEP):
        ex = CX + Rc * math.cos(math.radians(ang))
        ey = CY + Rc * math.sin(math.radians(ang))
        c = ring_color(ang)
        d.ellipse([ex - W/2, ey - W/2, ex + W/2, ey + W/2], fill=c)

# sphere
sr = int(plate * 0.16)
yy, xx = np.mgrid[-sr:sr, -sr:sr].astype(np.float32) / sr
rr2 = xx * xx + yy * yy
inside = rr2 <= 1.0
zz = np.sqrt(np.clip(1 - rr2, 0, 1))
L = np.array([-0.45, -0.5, 0.74]); L = L / np.linalg.norm(L)
ndl = np.clip(xx * L[0] + yy * L[1] + zz * L[2], 0, 1)
base = 0.28 + 0.64 * ndl
H = np.array([-0.35, -0.42, 0.84]); H = H / np.linalg.norm(H)
spec = np.clip(xx * H[0] + yy * H[1] + zz * H[2], 0, 1) ** 70 * 0.5
v = np.clip(base + spec, 0, 1) * 232
sph = np.zeros((2 * sr, 2 * sr, 4), dtype=np.float32)
sph[..., 0] = v; sph[..., 1] = v; sph[..., 2] = np.clip(v * 1.02, 0, 255)
alpha = inside * 255 * np.clip((1.0 - rr2) * sr * 0.9, 0, 1)
sph[..., 3] = alpha
img.alpha_composite(Image.fromarray(sph.astype(np.uint8), "RGBA"), (int(CX - sr), int(CY - sr)))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(out, exist_ok=True)
master = img.resize((1024, 1024), Image.LANCZOS)
for s in [16, 32, 64, 128, 256, 512, 1024]:
    master.resize((s, s), Image.LANCZOS).save(f"{out}/icon_{s}.png")
print("ok")
