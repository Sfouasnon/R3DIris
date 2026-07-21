#!/usr/bin/env python3
"""
sim_array.py — R3DIris test harness: N simulated RED bodies on loopback IPs.

Each simulated camera serves, per IP (defaults match real bodies):
  :9998  RCP2 WebSocket — the init sequence, subscriptions (TIMECODE 1/s),
         APERTURE get/set/list/set_list_relative with cur→target motor motion,
         APERTURE_CONTROL / AE / LIVESTREAM params.
  :9090  Multipart-HTTP MJPEG — a rendered gray sphere on a gray backdrop.
         Sphere brightness responds to the CURRENT iris position plus a
         per-camera T-stop calibration error (seeded), so bodies mismatch
         until the app's match loop converges them. Exposure ∝ (T_base/T)².
  :1112  UDP CAMINFO responder — answers the app's discovery broadcast
         (the TCP sweep also finds :9998 listening; both paths work).

Typical run (after ./setup_loopback.sh 12):
  python3 sim_array.py --count 12
  → cameras on 127.0.0.101 … 127.0.0.112; scan subnet "127.0.0.0/24" in R3DIris.

Quick single-body check without sudo (127.0.0.1 needs no alias):
  python3 sim_array.py --count 1 --base-ip 127.0.0.1

Self-test (no servers — verifies the rendered sphere passes the detection
gate metrics R3DIris ports from R3DMatch, and that brightness tracks iris):
  python3 sim_array.py --self-test

Requires: websockets, numpy, pillow   (pip install -r requirements.txt)
"""

import argparse
import asyncio
import io
import json
import math
import random
import socket
import struct
import sys
import time

import numpy as np
from PIL import Image

try:
    import websockets
except ImportError:
    websockets = None   # allowed for --self-test

WS_PORT = 9998
HTTP_PORT = 9090
UDP_PORT = 1112
BASE_STOP = 5.6          # exposure reference; brightness = (BASE/T)^2 * 2^cal_err

# Exact RED Log3G10 curve (white paper 915-0187 Rev-C; same constants as
# R3DMatch v5 and R3DIris/Analysis/Log3G10.swift).
LOG3G10_A = 0.224282
LOG3G10_B = 155.975327
LOG3G10_C = 0.01
LOG3G10_G = 15.1927


def log3g10_encode(linear):
    x = np.asarray(linear, dtype=np.float64)
    shifted = x + LOG3G10_C
    result = np.empty_like(shifted)
    positive = shifted >= 0
    result[positive] = LOG3G10_A * np.log10(
        shifted[positive] * LOG3G10_B + 1.0)
    result[~positive] = LOG3G10_G * shifted[~positive]
    return result


def log3g10_linearize(code):
    y = np.asarray(code, dtype=np.float64)
    result = np.empty_like(y)
    positive = y >= 0
    result[positive] = (
        np.power(10.0, y[positive] / LOG3G10_A) - 1.0
    ) / LOG3G10_B - LOG3G10_C
    result[~positive] = y[~positive] / LOG3G10_G - LOG3G10_C
    return result

ADVERTISED = [
    "RECORD_STATE", "TIMECODE", "APERTURE", "APERTURE_CONTROL",
    "APERTURE_LIST_MODE", "AE_MODE", "AE_LOCK_APERTURE",
    "LIVESTREAM_ENABLE", "LIVESTREAM_QUALITY",
    "LIVESTREAM_MIRROR_SOURCE", "LIVESTREAM_RECT_PIXELS",
    "DISPLAY_PRESET_SDI_1", "SDI_COLOR_SETTING_BUILT_IN_LCD",
    "SDI_COLOR_SETTING_SDI_1", "CLIP_NAME_2", "CLIP_NAME",
]

JPEG_QUALITY = {1: 40, 2: 60, 3: 80, 4: 95}   # LIVESTREAM_QUALITY 1..4


def quarter_stop_list():
    """Valid stop values ×10 in canonical photographic quarter-stops
    (T2.8–T16). Canonical labels, not raw ×2^(1/8) math, so common sets like
    56 (T5.6) and 80 (T8) are exactly representable — as on real lenses."""
    return [28, 31, 34, 37, 40, 44, 48, 52, 56, 62, 67, 73,
            80, 87, 95, 104, 113, 124, 135, 147, 160]


# ---------------------------------------------------------------------------
# Scene rendering
# ---------------------------------------------------------------------------

class Scene:
    """Static float32 scene (H,W,3 in [0,1]) with a Lambertian gray sphere.

    Geometry per camera is stable (seeded jitter); only brightness varies with
    the iris. The sphere is built to pass the R3DMatch-derived gates:
    neutral chroma, interior std in band, shadow terminator (dark/bright
    halves ratio < 0.96), specular lobe, IRE spread ≥ 0.8.
    """

    def __init__(self, width, height, rng):
        self.w, self.h = width, height
        cx = width * (0.50 + rng.uniform(-0.05, 0.05))
        cy = height * (0.52 + rng.uniform(-0.05, 0.05))
        r = width * (0.090 + rng.uniform(-0.008, 0.008))
        self.sphere = (cx, cy, r)

        yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)

        # Backdrop: gentle vertical gradient + vignette, neutral gray.
        base = 0.155 - 0.045 * (yy / height)
        vign = 1.0 - 0.25 * (((xx / width - 0.5) ** 2 + (yy / height - 0.5) ** 2) * 2)
        bg = base * vign

        # Sphere: Lambertian + specular, light from upper-left.
        sx = (xx - cx) / r
        sy = (yy - cy) / r
        rr2 = sx * sx + sy * sy
        inside = rr2 <= 1.0
        zz = np.sqrt(np.clip(1 - rr2, 0, 1))
        L = np.array([-0.55, -0.45, 0.70], dtype=np.float32)
        L /= np.linalg.norm(L)
        ndl = np.clip(sx * L[0] + sy * L[1] + zz * L[2], 0, 1)
        H = np.array([-0.42, -0.35, 0.84], dtype=np.float32)
        H /= np.linalg.norm(H)
        spec = np.clip(sx * H[0] + sy * H[1] + zz * H[2], 0, 1) ** 55 * 0.28

        albedo = 0.42   # renders the hero center near ~45 IRE at T5.6 nominal
        sphere_lum = albedo * (0.22 + 0.78 * ndl) + spec

        lum = np.where(inside, sphere_lum, bg).astype(np.float32)
        # Neutral RGB with a hair of channel variation (keeps JPEG honest,
        # stays inside the chroma gate).
        self.rgb = np.stack([lum * 0.997, lum, lum * 1.003], axis=-1)
        self._background = np.stack([bg * 0.997, bg, bg * 1.003], axis=-1)
        self._sphere_delta = self.rgb - self._background

    def _rgb_at_offset(self, dx, dy):
        """Move only the sphere layer; keep the backdrop fixed, with no wrap."""
        ix, iy = int(round(dx)), int(round(dy))
        if ix == 0 and iy == 0:
            return self.rgb
        shifted = np.zeros_like(self._sphere_delta)
        sx0, sx1 = max(0, -ix), min(self.w, self.w - ix)
        sy0, sy1 = max(0, -iy), min(self.h, self.h - iy)
        if sx0 < sx1 and sy0 < sy1:
            shifted[sy0 + iy:sy1 + iy, sx0 + ix:sx1 + ix] = \
                self._sphere_delta[sy0:sy1, sx0:sx1]
        return self._background + shifted

    def frame(self, brightness, occluded=False, noise=0.004, rng=None,
              drift=(0.0, 0.0), transform="display"):
        img = self._rgb_at_offset(*drift) * brightness
        if occluded:
            cx, cy, r = self.sphere
            cx += drift[0]
            cy += drift[1]
            x0, x1 = int(cx - r * 1.3), int(cx + r * 1.3)
            y0, y1 = int(cy - r * 1.3), int(cy + r * 1.3)
            img = img.copy()
            img[max(0, y0):y1, max(0, x0):x1] = 0.13 * brightness  # matte flag
        if transform == "log3g10":
            img = log3g10_encode(img)
        if noise > 0:
            n = (np.random.default_rng().standard_normal(img.shape) * noise
                 if rng is None else rng.standard_normal(img.shape) * noise)
            img = img + n.astype(np.float32)
        return (np.clip(img, 0, 1) * 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# Simulated camera
# ---------------------------------------------------------------------------

class SimCamera:
    def __init__(self, index, ip, args, seed):
        self.ip = ip
        self.name = f"SIM-{index + 1:02d}"
        self.serial = f"SIM{index + 1:05d}"
        # CLIP_NAME drives the array identifier: "G001_A001" → "GA", "G001_B001"
        # → "GB", … (reel/group letter + camera letter), matching real RCP2.
        self.clip_name = f"G001_{chr(ord('A') + (index % 26))}001"
        rng = random.Random(seed)
        self.scene = Scene(args.width, args.width * 9 // 16,
                           random.Random(seed + 1))
        # Per-camera T-stop calibration error → the exposure mismatch the
        # app's match loop must dial out.
        self.cal_err = rng.uniform(-args.spread / 2, args.spread / 2)

        self.stop_list = quarter_stop_list()
        start = min(range(len(self.stop_list)),
                    key=lambda i: abs(self.stop_list[i] - BASE_STOP * 10))
        self.cur_idx = start
        self.target_idx = start

        self.subs = set()
        self.livestream_enabled = 1 if args.autostream else 0
        self.livestream_quality = 4
        self.record_state = 0
        self.fps = args.fps
        self.occlude_every = args.occlude_every
        self.drift_px_per_min = args.drift
        self.flicker_stops_pp = args.flicker
        self.transform = args.transform
        self.display_preset = 0 if args.transform == "log3g10" else 6  # DISPLAY_LUT tone (unused by app)
        self.color_setting = 0 if args.transform == "log3g10" else 1   # COLOR_SETTING: 0=LOG3G10, 1=3D LUT
        self.mirror_source = 3  # TOP LCD (read-only status on real bodies)
        self.start_time = time.time()
        self.clients = set()          # websocket connections
        self.log = print if args.verbose else (lambda *a, **k: None)

    # -- state ---------------------------------------------------------------

    def stop_x10(self, idx):
        return self.stop_list[max(0, min(idx, len(self.stop_list) - 1))]

    def brightness(self):
        t = self.stop_x10(self.cur_idx) / 10.0
        base = (BASE_STOP / t) ** 2 * (2 ** self.cal_err)
        elapsed = time.time() - self.start_time
        flicker_stops = (self.flicker_stops_pp / 2.0) * math.sin(2 * math.pi * elapsed)
        return base * (2 ** flicker_stops)

    def drift_offset(self):
        elapsed = time.time() - self.start_time
        return (self.drift_px_per_min * elapsed / 60.0, 0.0)

    def occluded(self):
        if not self.occlude_every:
            return False
        t = time.time() - self.start_time
        return (t % self.occlude_every) > (self.occlude_every - 2.0)

    def timecode(self):
        t = time.time() - self.start_time
        fr = int((t % 1) * 24)
        s = int(t)
        return f"{(s // 3600) % 24:02d}:{(s // 60) % 60:02d}:{s % 60:02d}:{fr:02d}"

    # -- message shapes (what the app's defensive parsers expect) -------------

    def msg_for(self, pid):
        if pid == "APERTURE":
            return {"type": "rcp_cur_int", "id": "APERTURE",
                    "cur": {"val": self.stop_x10(self.cur_idx)},
                    "target": {"val": self.stop_x10(self.target_idx)}}
        if pid == "TIMECODE":
            return {"type": "rcp_cur_tc", "id": "TIMECODE",
                    "cur": {"str": self.timecode()}}
        if pid == "LIVESTREAM_RECT_PIXELS":
            return {"type": "rcp_cur_str", "id": pid,
                    "cur": {"str": f"0,0,{self.scene.w},{self.scene.h}"}}
        if pid in ("CLIP_NAME", "CLIP_NAME_2"):
            return {"type": "rcp_cur_str", "id": pid, "cur": {"str": self.clip_name}}
        ints = {
            "RECORD_STATE": self.record_state,
            "APERTURE_CONTROL": 1,          # every sim body is e-iris
            "APERTURE_LIST_MODE": 0,        # 1/4-stop
            "AE_MODE": 0,
            "AE_LOCK_APERTURE": 0,
            "LIVESTREAM_ENABLE": self.livestream_enabled,
            "LIVESTREAM_QUALITY": self.livestream_quality,
            "LIVESTREAM_MIRROR_SOURCE": self.mirror_source,
            "DISPLAY_PRESET_SDI_1": self.display_preset,
            "SDI_COLOR_SETTING_BUILT_IN_LCD": self.color_setting,
            "SDI_COLOR_SETTING_SDI_1": self.color_setting,
        }
        if pid in ints:
            return {"type": "rcp_cur_int", "id": pid, "cur": {"val": ints[pid]}}
        return None

    async def push(self, pid):
        msg = self.msg_for(pid)
        if msg is None:
            return
        data = json.dumps(msg)
        for ws in list(self.clients):
            try:
                await ws.send(data)
            except Exception:
                self.clients.discard(ws)

    # -- WS protocol ----------------------------------------------------------

    async def handle_ws(self, ws):
        self.clients.add(ws)
        self.log(f"[{self.name}] WS connect")
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except Exception:
                    continue
                await self.dispatch(ws, msg)
        except Exception:
            pass
        finally:
            self.clients.discard(ws)
            self.log(f"[{self.name}] WS closed")

    async def dispatch(self, ws, msg):
        mtype = msg.get("type", "")
        pid = str(msg.get("id", "")).replace("RCP_PARAM_", "")

        if mtype == "rcp_config":
            return
        if mtype == "rcp_get_types":
            await ws.send(json.dumps({"type": "rcp_cur_types", "types": []}))
            return
        if mtype == "rcp_get" and pid == "CAMERA_INFO":
            await ws.send(json.dumps({
                "type": "rcp_cur_cam_info", "id": "CAMERA_INFO",
                "name": self.name, "serial_number": self.serial,
                "version": {"str": "7.4.1-sim"}}))
            return
        if mtype == "rcp_get_parameters":
            await ws.send(json.dumps({"type": "rcp_cur_parameters",
                                      "parameters": ADVERTISED}))
            return
        if mtype == "rcp_subscribe":
            if msg.get("on_off"):
                self.subs.add(pid)
                await self.push(pid)      # cameras push current state on subscribe
            else:
                self.subs.discard(pid)
            return
        if mtype == "rcp_get":
            reply = self.msg_for(pid)
            if reply is not None:
                await ws.send(json.dumps(reply))
            return
        if mtype == "rcp_get_list" and pid == "LIVESTREAM_QUALITY":
            await ws.send(json.dumps({
                "type": "rcp_cur_list", "id": "LIVESTREAM_QUALITY",
                "list": [{"val": v} for v in (1, 2, 3, 4)]}))
            return
        if mtype == "rcp_get_list" and pid == "APERTURE":
            await ws.send(json.dumps({
                "type": "rcp_cur_list", "id": "APERTURE",
                "list": [{"val": v} for v in self.stop_list]}))
            return
        if mtype == "rcp_set":
            await self.handle_set(pid, msg.get("value"))
            return
        if mtype == "rcp_set_list_relative" and pid == "APERTURE":
            off = int(msg.get("offset", 0))
            self.target_idx = max(0, min(self.target_idx + off,
                                         len(self.stop_list) - 1))
            self.log(f"[{self.name}] nudge {off:+d} → target "
                     f"T{self.stop_x10(self.target_idx) / 10}")
            await self.push("APERTURE")
            return

    async def handle_set(self, pid, value):
        if value is None:
            return
        v = int(value)
        if pid == "APERTURE":
            self.target_idx = min(range(len(self.stop_list)),
                                  key=lambda i: abs(self.stop_list[i] - v))
            self.log(f"[{self.name}] set APERTURE {v} → target "
                     f"T{self.stop_x10(self.target_idx) / 10}")
            await self.push("APERTURE")
        elif pid == "LIVESTREAM_ENABLE":
            self.livestream_enabled = v
            await self.push(pid)
        elif pid == "LIVESTREAM_QUALITY":
            self.livestream_quality = max(1, min(v, 4))
            await self.push(pid)
        elif pid == "DISPLAY_PRESET_SDI_1":
            self.display_preset = max(0, min(v, 7))
            await self.push(pid)
        elif pid in ("SDI_COLOR_SETTING_BUILT_IN_LCD", "SDI_COLOR_SETTING_SDI_1"):
            # The "Look": 0 = LOG (RWG/Log3G10), 1 = 3D LUT, 2 = Custom Display.
            self.color_setting = max(0, min(v, 2))
            self.transform = "log3g10" if self.color_setting == 0 else "display"
            await self.push(pid)

    # -- background: iris motor + timecode ------------------------------------

    async def motor_loop(self):
        while True:
            await asyncio.sleep(0.15)
            if self.cur_idx != self.target_idx:
                self.cur_idx += 1 if self.target_idx > self.cur_idx else -1
                if "APERTURE" in self.subs:
                    await self.push("APERTURE")

    async def timecode_loop(self):
        while True:
            await asyncio.sleep(1.0)
            if "TIMECODE" in self.subs:
                await self.push("TIMECODE")

    # -- MJPEG ----------------------------------------------------------------

    def jpeg(self):
        arr = self.scene.frame(self.brightness(), occluded=self.occluded(),
                               drift=self.drift_offset(), transform=self.transform)
        buf = io.BytesIO()
        Image.fromarray(arr, "RGB").save(
            buf, "JPEG", quality=JPEG_QUALITY[self.livestream_quality])
        return buf.getvalue()

    async def handle_http(self, reader, writer):
        try:
            # Consume the request head; path is irrelevant (root serves).
            while True:
                line = await asyncio.wait_for(reader.readline(), timeout=5)
                if not line or line in (b"\r\n", b"\n"):
                    break
            writer.write(
                b"HTTP/1.0 200 OK\r\n"
                b"Content-Type: multipart/x-mixed-replace; boundary=simframe\r\n"
                b"Cache-Control: no-cache\r\n"
                b"Connection: close\r\n\r\n")
            await writer.drain()
            self.log(f"[{self.name}] MJPEG client connected")
            interval = 1.0 / self.fps
            loop = asyncio.get_running_loop()
            while True:
                start = loop.time()
                jpeg = await loop.run_in_executor(None, self.jpeg)
                writer.write(b"--simframe\r\n"
                             b"Content-Type: image/jpeg\r\n"
                             + f"Content-Length: {len(jpeg)}\r\n\r\n".encode()
                             + jpeg + b"\r\n")
                await writer.drain()
                await asyncio.sleep(max(0, interval - (loop.time() - start)))
        except (ConnectionResetError, BrokenPipeError, asyncio.TimeoutError):
            pass
        except Exception as e:
            self.log(f"[{self.name}] MJPEG error: {e}")
        finally:
            try:
                writer.close()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# UDP CAMINFO discovery responder
# ---------------------------------------------------------------------------

class CamInfoProtocol(asyncio.DatagramProtocol):
    def __init__(self, cam):
        self.cam = cam
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if b"CAMINFO" not in data:
            return
        body = f"$API:A:CAMINFO:{self.cam.name}:7.4.1:{self.cam.serial}"
        checksum = 0
        for b in body.encode():
            checksum ^= b
        reply = f"#{body}*{checksum:02X}\n".encode()
        self.transport.sendto(reply, addr)


# ---------------------------------------------------------------------------
# Self-test: gate metrics on the rendered sphere (mirrors SphereDetector.swift)
# ---------------------------------------------------------------------------

def self_test(args):
    print("self-test: rendering one camera's scene and checking gate metrics")
    cam = SimCamera(0, "127.0.0.1", args, seed=args.seed)
    cx, cy, r = cam.scene.sphere

    def luma(arr):
        f = arr.astype(np.float32) / 255.0
        return 0.2126 * f[..., 0] + 0.7152 * f[..., 1] + 0.0722 * f[..., 2]

    def metrics(arr):
        g = luma(arr)
        h, w = g.shape
        yy, xx = np.mgrid[0:h, 0:w]
        dist = np.hypot(xx - cx, yy - cy)
        interior = dist <= r
        m = {}
        m["std_full_r"] = float(g[interior].std())
        m["std_085r"] = float(g[dist <= r * 0.85].std())
        f = arr.astype(np.float32)[interior]
        mean = f.mean(axis=0)
        tot = mean.sum()
        rc, gc = mean[0] / tot, mean[1] / tot
        m["chroma_dist"] = float(math.hypot(rc - 1 / 3, gc - 1 / 3))
        m["rg"], m["bg"] = float(mean[0] / mean[1]), float(mean[2] / mean[1])
        # shadow ratio at 0.7r, split along center→peak axis
        m07 = dist <= r * 0.7
        vals = g[m07]
        iy, ix = np.where(m07)
        pk = np.argmax(vals)
        dx, dy = ix[pk] - cx, iy[pk] - cy
        n = math.hypot(dx, dy)
        dx, dy = (dx / n, dy / n) if n > 1 else (1, 0)
        proj = (ix - cx) * dx + (iy - cy) * dy
        bright = vals[proj >= 0].mean()
        dark = vals[proj < 0].mean()
        m["shadow_ratio"] = float(dark / bright)
        # hero IRE (0.24r disk median) + spread probes at ±0.24r
        def hero(px, py, pr):
            mask = np.hypot(xx - px, yy - py) <= pr * 0.24
            v = g[mask]
            v = v[v > 0]
            if len(v) < 4:
                return None
            lo, hi = np.percentile(v, [5, 95])
            t = v[(v >= lo) & (v <= hi)]
            return float(np.median(t)) * 100
        m["hero_ire"] = hero(cx, cy, r)
        b = hero(cx + 0.24 * r, cy, r * 0.20)
        dk = hero(cx - 0.24 * r, cy, r * 0.20)
        m["ire_spread"] = abs(b - dk) if b and dk else 0.0
        return m

    def jpeg_roundtrip(arr, quality=95):
        buf = io.BytesIO()
        Image.fromarray(arr, "RGB").save(buf, "JPEG", quality=quality)
        return np.array(Image.open(io.BytesIO(buf.getvalue())).convert("RGB"))

    ok = True

    def check(label, cond, detail):
        nonlocal ok
        print(f"  [{'PASS' if cond else 'FAIL'}] {label}: {detail}")
        ok = ok and cond

    m = metrics(cam.scene.frame(1.0, noise=0.004, transform="display"))
    check("interior std (0.008–0.130)", 0.008 <= m["std_full_r"] <= 0.130,
          f"{m['std_full_r']:.4f}")
    check("interior std 0.85r (0.003–0.170)", 0.003 <= m["std_085r"] <= 0.170,
          f"{m['std_085r']:.4f}")
    check("chroma distance ≤ 0.045", m["chroma_dist"] <= 0.045,
          f"{m['chroma_dist']:.4f}")
    check("R/G in 0.90–1.25, B/G in 0.80–1.20",
          0.90 <= m["rg"] <= 1.25 and 0.80 <= m["bg"] <= 1.20,
          f"rg={m['rg']:.3f} bg={m['bg']:.3f}")
    check("shadow ratio ≤ 0.96", m["shadow_ratio"] <= 0.96,
          f"{m['shadow_ratio']:.4f}")
    check("IRE spread ≥ 0.8", m["ire_spread"] >= 0.8,
          f"{m['ire_spread']:.2f}")
    check("hero IRE plausible (18–65)", 18 <= (m["hero_ire"] or 0) <= 65,
          f"{m['hero_ire']:.1f}")

    # Brightness must track the iris: T5.6 → T8 should drop ~1 stop.
    i56 = cam.cur_idx
    ire_56 = metrics(cam.scene.frame(cam.brightness(), noise=0,
                                     transform="display"))["hero_ire"]
    cam.cur_idx = cam.target_idx = min(
        range(len(cam.stop_list)), key=lambda i: abs(cam.stop_list[i] - 80))
    ire_80 = metrics(cam.scene.frame(cam.brightness(), noise=0,
                                     transform="display"))["hero_ire"]
    cam.cur_idx = cam.target_idx = i56
    stops = math.log2(ire_56 / ire_80) if ire_80 else 0
    check("T5.6→T8 drops ~1 stop (0.7–1.3)", 0.7 <= stops <= 1.3,
          f"measured {stops:.2f} stops (IRE {ire_56:.1f} → {ire_80:.1f})")

    # JPEG round-trip at Q95 keeps metrics in band.
    display_jpeg = jpeg_roundtrip(
        cam.scene.frame(cam.brightness(), noise=0.004, transform="display"))
    jm = metrics(display_jpeg)
    check("post-JPEG shadow ratio ≤ 0.96", jm["shadow_ratio"] <= 0.96,
          f"{jm['shadow_ratio']:.4f}")
    check("post-JPEG chroma ≤ 0.045", jm["chroma_dist"] <= 0.045,
          f"{jm['chroma_dist']:.4f}")

    # Exact Log3G10 math and end-to-end exposure recovery.
    samples = np.array([-0.02, -0.01, 0.0, 0.18, 0.5, 1.0], dtype=np.float64)
    roundtrip = log3g10_linearize(log3g10_encode(samples))
    roundtrip_error = float(np.max(np.abs(roundtrip - samples)))
    check("Log3G10 round-trip ≤ 1e-6", roundtrip_error <= 1e-6,
          f"max error {roundtrip_error:.3e}")

    anchor_math = float(log3g10_encode(np.array(0.18))) * 100.0
    check("18% gray Log3G10 anchor near 33.3 IRE",
          abs(anchor_math - 33.3333) <= 0.05, f"{anchor_math:.3f} IRE")

    flat_gray = np.full((cam.scene.h, cam.scene.w, 3), 0.18, dtype=np.float32)
    flat_log = (np.clip(log3g10_encode(flat_gray), 0, 1) * 255).astype(np.uint8)
    anchor_jpeg = metrics(jpeg_roundtrip(flat_log))["hero_ire"]
    check("18% gray post-JPEG hero near 33.3 IRE",
          anchor_jpeg is not None and abs(anchor_jpeg - 33.3333) <= 0.8,
          f"{anchor_jpeg:.3f} IRE")

    cam.cur_idx = cam.target_idx = i56
    log56 = jpeg_roundtrip(cam.scene.frame(cam.brightness(), noise=0,
                                           transform="log3g10"))
    ire_56_log = metrics(log56)["hero_ire"]
    cam.cur_idx = cam.target_idx = min(
        range(len(cam.stop_list)), key=lambda i: abs(cam.stop_list[i] - 80))
    log80 = jpeg_roundtrip(cam.scene.frame(cam.brightness(), noise=0,
                                           transform="log3g10"))
    ire_80_log = metrics(log80)["hero_ire"]
    cam.cur_idx = cam.target_idx = i56
    lin56 = float(log3g10_linearize(np.array(ire_56_log / 100.0)))
    lin80 = float(log3g10_linearize(np.array(ire_80_log / 100.0)))
    measured_log_stops = math.log2(lin56 / lin80)
    expected_log_stops = 2 * math.log2(8.0 / 5.6)
    check("Log3G10 linearize recovers iris delta within 0.05 stop",
          abs(measured_log_stops - expected_log_stops) <= 0.05,
          f"measured {measured_log_stops:.3f}, expected {expected_log_stops:.3f}")

    logm = metrics(log56)
    check("Log3G10 post-JPEG shadow gate ≤ 0.985",
          logm["shadow_ratio"] <= 0.985, f"{logm['shadow_ratio']:.4f}")
    check("Log3G10 post-JPEG IRE spread ≥ 0.8",
          logm["ire_spread"] >= 0.8, f"{logm['ire_spread']:.2f}")
    check("Log3G10 post-JPEG interior std in gate band",
          0.003 <= logm["std_085r"] <= 0.170, f"{logm['std_085r']:.4f}")

    print("self-test:", "ALL PASS" if ok else "FAILURES — fix scene params")
    return 0 if ok else 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def run(args):
    if websockets is None:
        print("error: `pip install websockets` (see requirements.txt)")
        return 1
    base = args.base_ip.split(".")
    base_last = int(base[3])
    prefix = ".".join(base[:3])

    cams = []
    for i in range(args.count):
        ip = f"{prefix}.{base_last + i}"
        cam = SimCamera(i, ip, args, seed=args.seed + i * 7)
        cams.append(cam)

    loop = asyncio.get_running_loop()
    started = []
    for cam in cams:
        try:
            ws_server = await websockets.serve(
                cam.handle_ws, cam.ip, args.ws_port,
                ping_interval=None)          # rule 5: cameras don't ping
            http_server = await asyncio.start_server(
                cam.handle_http, cam.ip, args.http_port)
            await loop.create_datagram_endpoint(
                lambda c=cam: CamInfoProtocol(c),
                local_addr=(cam.ip, UDP_PORT))
            started.append(cam)
            asyncio.ensure_future(cam.motor_loop())
            asyncio.ensure_future(cam.timecode_loop())
        except OSError as e:
            print(f"  {cam.ip}: BIND FAILED ({e}) — run setup_loopback.sh?")
    if not started:
        return 1

    print(f"\nsim array up — {len(started)} camera(s):")
    for cam in started:
        print(f"  {cam.ip:<16} {cam.name}  cal_err {cam.cal_err:+.2f} stops"
              f"  sphere r={cam.scene.sphere[2]:.0f}px")
    print(f"  transform={args.transform}  drift={args.drift:.2f}px/min"
          f"  flicker={args.flicker:.3f} stops p-p")
    print(f"\nR3DIris: scan subnet \"{prefix}.0/24\" (or add IPs manually).")
    print("Ctrl-C to stop.\n")
    await asyncio.Event().wait()


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--count", type=int, default=12, help="number of cameras (12–40 typical)")
    p.add_argument("--base-ip", default="127.0.0.101", help="first camera IP")
    p.add_argument("--fps", type=float, default=6, help="MJPEG frame rate")
    p.add_argument("--width", type=int, default=640, help="stream width (16:9)")
    p.add_argument("--spread", type=float, default=1.0,
                   help="T-stop calibration error spread across the array (stops)")
    p.add_argument("--seed", type=int, default=7, help="mismatch seed (reproducible)")
    p.add_argument("--occlude-every", type=float, default=0,
                   help="every N seconds, occlude the sphere for 2 s (tracker test)")
    p.add_argument("--drift", type=float, default=0,
                   metavar="PX_PER_MIN",
                   help="slow horizontal sphere drift in detection pixels per minute")
    p.add_argument("--flicker", type=float, default=0,
                   metavar="STOPS_PP",
                   help="1 Hz sinusoidal brightness flicker, peak-to-peak stops")
    p.add_argument("--transform", choices=("log3g10", "display"), default="display",
                   help="livestream viewing transform (default: display)")
    p.add_argument("--autostream", action="store_true",
                   help="report LIVESTREAM_ENABLE=1 from boot")
    p.add_argument("--ws-port", type=int, default=WS_PORT)
    p.add_argument("--http-port", type=int, default=HTTP_PORT)
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()

    if args.self_test:
        sys.exit(self_test(args))
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
