# R3DIris — Phase 0 bench spike + Phase 2 Iris Match + Sphere Soak

Native SwiftUI macOS app (same stack and transport discipline as REDConductorV3).
Two tabs:

- **Bench** (Phase 0): answers the single-body go/no-go gate —
  can we pull live pixels over IP **and** dial the electronic iris over RCP2?
- **Array** (Phase 2, added 2026-07-17): the **Iris Match** — bulk T-stop push
  to every e-iris body plus the closed sphere-targeted exposure-match loop.
  Sphere auto-detection is R3DMatch v5's calibrated
  pipeline ported to Swift for live MJPEG frames. The Array tab also includes
  a distinct Manual Assist workflow for hand-dialed lenses, a write-through
  Sphere Soak recorder, and Log3G10 viewing-transform preflight.

**Status: builds with Xcode 16.4** (ad-hoc, unsigned Debug build verified). Nothing here is
hardware-verified: every aperture, livestream, and transform parameter is
`# UNVERIFIED` until the bench procedures pass on a body. Phase 0 gates the Array
tab: do not point the match loop at an array before they pass.
Bench day run-sheet (consolidated, manual-lens-aware): `BENCH_DAY_PLAN.md`.

## Build / run

1. Open `R3DIris.xcodeproj` in Xcode 16+ (macOS 14+ target, ad-hoc signing).
2. Build & run. Approve the **Local Network** permission prompt — without it
   everything fails silently.
3. Enter the camera IP (WS control on :9998, livestream on :9090). For
   link-local camera networks set the source IP of the correct NIC.

## Layout

```
R3DIris/
  R3DIrisApp.swift            @main
  Models.swift                CameraStatus + log line
  BenchController.swift       @MainActor UI bridge; owns the bench log
  RCP2Core/                   transport, discovery, state, and camera commands
    RCP2.swift                constants + defensive parsers (+ aperture helpers)
    RCP2Session.swift         NWConnection WS — ported unchanged from V3
    CameraActor.swift         V3's proven lifecycle + Phase 0 bench surface
    TCPScan.swift             subnet TCP sweep on :9998 — ported unchanged from V3
    UDPDiscovery.swift        CAMINFO broadcast (UDP :1112) — ported unchanged from V3
  Livestream/
    MJPEGStreamReader.swift   :9090 multipart-JPEG reader (SOI/EOI scan)
  Analysis/                   sphere detection + tracking + waveform + Log3G10
  Array/                      CameraNode + ArrayController + SoakRecorder
  UI/ContentView.swift        tabs; Bench tab: live view + bench panels + log
  UI/Theme.swift              V3/V2.1 visual language (Array tab styling)
  UI/ArrayView.swift          Array tab: discovery + tiles + match panels + waveform
```

Array-tab camera discovery is V3's method, ported unchanged: PRIMARY is a TCP
connect-sweep of the configured subnet on :9998 (no WS upgrade → zero session
slots), FALLBACK is the RCP-native CAMINFO broadcast on UDP :1112. Manual IP
entry remains as the fallback path for cameras discovery can't see.

## Test harness (no hardware)

`tools/simarray/` simulates 12–40 bodies on loopback IPs — RCP2 WS + MJPEG
gray-sphere stream + CAMINFO responder per IP, with seeded per-camera T-stop
calibration errors so the Exposure Match loop has real mismatch to solve. Use
`--transform log3g10`, `--drift PX_PER_MIN`, and `--flicker STOPS_PP` to exercise
the new QA paths. Install `tools/simarray/requirements.txt`, set up loopback
aliases with `tools/simarray/setup_loopback.sh`, then run `sim_array.py`. The
harness exercises the happy path;
the Phase 0 bench checklists remain the gate for real bodies.

## Identity

R3DIris has its own look (UI/Theme.swift): graphite neutrals with the iris
teal→violet duotone, `IrisMark` logo in the chrome, and a matching app icon
in `Assets.xcassets` (regenerate with `tools/icon/make_icon.py` if the mark
changes). Deliberately NOT REDConductorV3's palette: siblings, not clones.

`RCP2Core/` is adapted from REDConductorV3's proven transport. Camera-control
divergences are additive, operator-triggered, and marked `# UNVERIFIED` until
bench evidence supports them.

## Safety model

- One actor and one RCP2 WebSocket per camera body; MJPEG remains a separate
  HTTP connection on port 9090.
- Camera sessions close gracefully, reconnect with bounded backoff, and park
  after repeated failures.
- Unverified image-side parameters are touched only by deliberate operator
  actions and logged one camera at a time.
- Exposure Match requires connected e-iris bodies, live streams, sphere locks,
  and a homogeneous confirmed viewing transform. Mixed transforms are blocked.

## Bench procedure (the point of Phase 0)

Livestream half: **Enable + View** sets
`LIVESTREAM_ENABLE 1` over the WS then GETs `http://<cam>:9090/`. The log
records the HTTP headers and the first part's preamble (the actual boundary
format), then the stats bar gives resolution / fps / bitrate. Latency: wave at
the lens, compare against the log timestamps. Confirm TC keeps ticking in the
header while streaming (WS session health).

Aperture half: use the numbered buttons in order while watching
the TC tick after each — a timeout on an unverified param can mean a **wedged
session** (TCP up, pushes stopped; only reconnect clears it — rule 11). Values
are stop ×10 (56 = 5.6). Subscribe APERTURE to watch pushed cur/target converge
— cur == target is the settle detector the Phase 2 loop will use.

End-to-end (the actual R3DIris loop): stream running + dial aperture in the
same session, watch the image brighten/darken live. **Save Log…** — the log is
the deliverable. Only remove a `# UNVERIFIED` marker after recording repeatable
behavior on supported bodies and firmware.

## Phase 2 QA additions

The Array tab separates **Electronic** and **Manual Assist** workflows. Manual
Assist never sends aperture commands: it captures a fixed median, uses the 18%
gray Log3G10 anchor at 33.3 IRE, or accepts a custom IRE target. It temporarily
normalizes each mirrored output to Log3G10, then overlays live OPEN / CLOSE /
HOLD guidance on every camera feed. A camera must hold the
target tolerance before it is marked matched, and the whole array must verify
simultaneously. Finish and Abort both restore the display presets captured at
session start; restoration refuses to overwrite a mirror source or preset that
an operator changed during the session.

The Array tab's **Soak** card opens a CSV destination and records one row per
analysis tick, plus structured Exposure Match events. On Stop it writes a
`*_summary.txt` beside the CSV with detection rate, lock/recovery timing,
center/radius jitter, IRE stability, gate failures, and match readiness.

The **Set Log3G10 on Array** action changes only the active monitor output
preset feeding the livestream mirror, one body at a time, and reads it back.
Prepare and Start Match preflight every participant; mixed confirmed viewing
transforms are blocked. These output parameters remain `# UNVERIFIED` until
their on-body bench procedure passes.
