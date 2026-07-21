# R3DIris

**Match exposure across a multi-camera RED array to a single gray-sphere target — live, on set.**

R3DIris is a native macOS app for exposure-matching arrays of RED cameras (for
example a KOMODO-X volume) over the network. Point every camera at the same gray
sphere and R3DIris reads each camera's live image in the Log3G10 viewing
transform, tracks the sphere, and guides you to a common target (18% gray =
33.3 IRE) — then produces a report of the matched array.

It talks to cameras over RED's RCP2 control protocol and their built-in
livestream, so no capture or SDI hardware is required — just a network
connection.

## What it does

- **Array exposure matching** — discovers every camera on the network, tracks a
  gray sphere in each live feed, and shows how far each camera is from the shared
  IRE target.
- **Manual Assist for hand-dialed lenses** — live OPEN / CLOSE / HOLD guidance
  overlaid on each camera as you turn the iris ring; it never sends a lens
  command. A guided single-operator mode advances you camera-by-camera in
  fullscreen, waits for each to settle, and snaps back if a matched camera drifts.
- **Log3G10 viewing transform** — temporarily switches each camera's monitored
  output to RED Wide Gamut / Log3G10 so every camera is measured in the same
  space, and restores your original look when you finish.
- **Automatic sphere detection** — a calibrated detector locks onto the gray
  sphere on its own; one click accepts a mask, or click to place one by hand.
- **Match report** — a one-page PDF contact sheet: every camera's still with its
  sphere, IRE, delta from target, and match status, plus the array spread.
- **Soak recorder** — logs per-frame detection health to CSV with a summary
  (lock uptime, jitter, gate statistics) for confirming stability over time.
- **Resilient streaming** — automatically recovers dropped or stalled livestreams
  mid-session without losing your seeds or your match.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later to build
- RED cameras reachable on the local network — RCP2 control on TCP `:9998`,
  livestream on `:9090`. Validated on KOMODO-X (firmware 2.2.4).

## Getting started

1. Open `R3DIris.xcodeproj` in Xcode and Run (ad-hoc signing is fine).
2. Approve the **Local Network** permission on first launch — discovery and
   streaming won't work without it.
3. On the **Array** tab, cameras on your subnet are discovered automatically, or
   enter an IP manually. On a link-local camera network, set the source IP of the
   correct network interface.
4. Start the livestreams, place or accept a sphere mask on each camera, then run
   **Manual Assist** to match every camera to the target and save the report.

The **Bench** tab is a single-camera view for setup and diagnostics — confirm a
camera streams and responds before adding it to a match.

## How it works

Each camera runs on its own control connection (RCP2 over a WebSocket on `:9998`)
with the livestream as a separate HTTP/MJPEG feed on `:9090`. R3DIris measures a
fixed region of the gray sphere in every feed, expressed in Log3G10 IRE, and
reports each camera's offset from the shared target. Matching is operator-driven:
R3DIris measures and guides, you turn the ring — it never moves a lens or alters
a recorded image.

## Safety model

- One control connection and one livestream per camera; sessions close gracefully
  and reconnect with bounded backoff.
- Only the **monitored output** viewing transform is changed, one camera at a
  time, and it is always restored on Finish or Abort — recorded images and
  record-side color are never touched.
- Restoration refuses to overwrite an output that was changed mid-session.
- Matching requires live streams and a confirmed, consistent viewing transform
  across the array; mixed states are blocked.

## Development

Architecture (SwiftUI, `@MainActor` controllers with a per-camera actor for
transport):

```
R3DIris/
  RCP2Core/     camera transport, discovery, and control (RCP2 over WebSocket)
  Livestream/   MJPEG livestream reader (:9090)
  Analysis/     gray-sphere detection, tracking, waveform, Log3G10 math
  Array/        per-camera model, array controller, soak + report
  UI/           Bench and Array tabs, theme
```

A simulator (`tools/simarray/`) stands up 12–40 virtual cameras on loopback —
RCP2 + MJPEG gray-sphere stream + discovery per IP, with seeded per-camera
exposure errors — so the full workflow can be exercised without hardware. See
`tools/simarray/` for setup.

## Status

**Version 1.0.0 — first working release.** The exposure-matching workflow
(discovery, livestream, Log3G10 viewing transform, sphere detection, and Manual
Assist) is verified on KOMODO-X hardware. The electronic e-iris path (driving an
iris directly over RCP2) is experimental and not yet hardware-verified; it is
kept out of automatic use and gated behind deliberate operator actions.

See `CHANGELOG.md` for version history.
