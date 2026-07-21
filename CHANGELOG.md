# Changelog

All notable changes to R3DIris are recorded here.

This project follows [Semantic Versioning](https://semver.org) — `MAJOR.MINOR.PATCH`:

- **MAJOR** — breaking changes to the workflow or on-camera behavior.
- **MINOR** — new features, backward compatible.
- **PATCH** — bug fixes and tuning, no new features.

The app version lives in the Xcode target (`MARKETING_VERSION`) and each release
is git-tagged `vX.Y.Z`. Keep an entry under **[Unreleased]** as you work; move it
under a new version heading when you tag.

## [Unreleased]

### Changed
- Rewrote `README.md` as a product-facing overview (removed internal
  phase/bench-spike framing and predecessor-project references).

## [1.0.0] — 2026-07-21

First working end-to-end version. A 12-camera KOMODO-X array was discovered,
seeded, and calibrated to a fixed 33.3 IRE gray target in Log3G10 on the bench,
with a match report produced and the display transform cleanly restored.

### Added
- **Manual Assist calibration** — capture a fixed IRE target from stable sphere
  measurements and give live OPEN/CLOSE iris guidance per camera; never sends an
  aperture command.
- **Guided single-operator flow** — fullscreen auto-advance in camera-ID order
  with a settle dwell before moving on, snap-back to any camera that drifts out,
  a **Next Camera** button, and one-click **Lock Mask** to accept a good
  auto-detected sphere without opening the camera.
- **PDF match report** — one-page contact sheet (still + sphere overlay + IRE +
  delta + status per camera, with array-spread summary), available any time a
  match is live.
- **Live sphere soak** recorder with per-camera CSV + summary (lock uptime,
  jitter, relocks, gate-failure tally).
- **Stream resilience** — a manual *Reconnect Streams* action plus automatic
  recovery that restarts a dropped/stalled livestream in place (per-camera
  backoff) without ending a match or losing seeds.
- **Sphere detector diagnostics** — opt-in log of the Hough candidate count,
  support, and per-gate ladder for un-seeded cameras.

### Fixed
- **Log3G10 monitor swap** now uses the real per-output `SDI_COLOR_SETTING` Look
  (bare for SDI-1, `DSI_1` for the top-port monitor) resolved from the live
  livestream mirror source — verified against a RED Control Pro packet capture.
  Participant masks are frozen through the swap so they hold lock.
- **`ire_spread` gate structural-zero** on small livestream spheres: the ported
  probe went sub-pixel (~0.8px) and rejected the real sphere ~1400×/soak. The
  probe is now pixel-floored; false rejections dropped to ~0.
- Reduced measurement latency on the actively-trimmed camera; corrected a
  misleading "outputs already Log3G10" end message.

### Verified on hardware (KOMODO-X, FW 2.2.4)
- RCP2 discovery/transport, livestream, mirror source, the Log3G10 viewing
  transform, and sphere detection over a 30-minute soak (seeded masks: 100%
  detection, zero drift).

### Not yet verified
- Aperture / e-iris electronic loop — no e-iris body has been benched (test
  bodies reported `APERTURE_CONTROL` unsupported). This path retains its
  `# UNVERIFIED` guards in code.

[Unreleased]: https://github.com/Sfouasnon/R3DIris/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Sfouasnon/R3DIris/releases/tag/v1.0.0
