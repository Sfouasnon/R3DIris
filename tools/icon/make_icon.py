"""R3DIris app icon v2 — precision-instrument mark: dark squircle, thin
graphite ring, single teal index arc (80 deg, round caps, top-right), softly
lit gray sphere. 4x supersampled -> icon_{16..1024}.png."""
import math, os
import numpy as np
from PIL import Image, ImageDraw

S = 4096
CX = CY = S / 2
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

plate = S * 832 // 1024
p0 = (S - plate) // 2
rad = int(plate * 0.225)
grad = np.zeros((plate, plate, 4), dtype=np.uint8)
top = np.array([24, 25, 29]); bot = np.array([12, 13, 15])
for y in range(plate):
    t = y / plate
    grad[y, :, :3] = (top * (1 - t) + bot * t).astype(np.uint8)
    grad[y, :, 3] = 255
plate_img = Image.fromarray(grad, "RGBA")
mask = Image.new("L", (plate, plate), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, plate - 1, plate - 1], radius=rad, fill=255)
img.paste(plate_img, (p0, p0), mask)
d = ImageDraw.Draw(img)

TEAL = (63, 216, 199, 255)
RING = (73, 79, 89, 255)

R = plate * 0.315            # ring outer-edge radius
w_ring = plate * 0.017
w_arc = plate * 0.032
mid = R - w_ring / 2         # ring centerline radius

# base ring (PIL arc strokes inward from bbox radius R)
d.arc([CX - R, CY - R, CX + R, CY + R], start=0, end=360,
      fill=RING, width=int(w_ring))

# accent arc centered on the ring centerline: bbox radius Rb
Rb = mid + w_arc / 2
a0, a1 = -74, 6              # 80 deg sweep in the top-right quadrant
d.arc([CX - Rb, CY - Rb, CX + Rb, CY + Rb], start=a0, end=a1,
      fill=TEAL, width=int(w_arc))
for ang in (a0, a1):         # round caps at centerline radius
    ex = CX + mid * math.cos(math.radians(ang))
    ey = CY + mid * math.sin(math.radians(ang))
    d.ellipse([ex - w_arc/2, ey - w_arc/2, ex + w_arc/2, ey + w_arc/2], fill=TEAL)

# gray target sphere, upper-left key light
sr = int(plate * 0.115)
yy, xx = np.mgrid[-sr:sr, -sr:sr].astype(np.float32) / sr
rr2 = xx * xx + yy * yy
inside = rr2 <= 1.0
zz = np.sqrt(np.clip(1 - rr2, 0, 1))
L = np.array([-0.45, -0.5, 0.74]); L = L / np.linalg.norm(L)
ndl = np.clip(xx * L[0] + yy * L[1] + zz * L[2], 0, 1)
base = 0.30 + 0.60 * ndl
H = np.array([-0.35, -0.42, 0.84]); H = H / np.linalg.norm(H)
spec = np.clip(xx * H[0] + yy * H[1] + zz * H[2], 0, 1) ** 70 * 0.42
v = np.clip(base + spec, 0, 1) * 225
sph = np.zeros((2 * sr, 2 * sr, 4), dtype=np.float32)
sph[..., 0] = v; sph[..., 1] = v; sph[..., 2] = np.clip(v * 1.02, 0, 255)
sph[..., 3] = inside * 255 * np.clip((1.0 - rr2) * sr * 0.9, 0, 1)
img.alpha_composite(Image.fromarray(sph.astype(np.uint8), "RGBA"),
                    (int(CX - sr), int(CY - sr)))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(out, exist_ok=True)
master = img.resize((1024, 1024), Image.LANCZOS)
for s in [16, 32, 64, 128, 256, 512, 1024]:
    master.resize((s, s), Image.LANCZOS).save(f"{out}/icon_{s}.png")
print("ok")
