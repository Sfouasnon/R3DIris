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

### Added
- **Manual iris override in Electronic mode.** After the loop drives every lens to
  the target, the operator can nudge any e-iris body one list step open or closed
  — per-camera Open/Close in the Match Loop table, or Open all / Close all for a
  deliberate global bias. It reuses the loop's list-relative step and is only
  available while the loop is idle, so it can never fight convergence. An override
  is a deliberate move off the computed match: the loop never auto-undoes it —
  re-running the match (which resets the per-camera state) is the only thing that
  clears it. Overridden cameras carry a distinct **MATCHED · OVERRIDE (n open/
  close)** identifier on the tile chip and in the table, and every override is
  written to the log and soak record so an intentional bias is never mistaken for
  a calibration error.
- **Hybrid workflow replaces Manual Assist — the array is now two modes,
  Electronic and Hybrid.** Hybrid captures one shared target, hand-guides manual
  glass with live OPEN / CLOSE, and lets the operator push any e-iris participant
  toward the target on command (per-camera **PUSH** on each e-iris row and an
  array-wide **Push N e-iris → target**). The push reuses the Electronic loop's
  quarter-stop list-relative nudge, so a hand on the ring and a driven motor
  behave identically; it is operator-approved (never timed) and never sends a
  command to manual glass. This is the mixed-array case: motorized and manual
  lenses calibrated in one session instead of picking a single mode. An
  all-manual rig behaves exactly like the old Manual Assist; an all-e-iris rig
  gets push buttons instead of hand-trims. Prepare (e-iris gate + stop list) is
  now available in both modes because Hybrid needs it to know which bodies it can
  drive.
- **"Seed all solved"** locks every camera's current auto-detected sphere as a
  durable operator seed in one click. Auto-detected locks are transient and can
  coast out across a workflow switch or the Log3G10 swap; running this before
  leaving Electronic keeps the solve so switching into Hybrid never loses it.
- **Freshest frame** mode in the match panel decodes only the newest livestream
  frame when frames back up and is enabled by default.
- **Bench IRE validation** captures 300 untouched port-9090 JPEGs per trial for
  simultaneous comparison with a 10-bit SDI waveform reading from Nobe
  OmniScope. It supports gray-card, gray-sphere, and four-corner Macbeth chart
  ROIs and exports the source JPEGs, measurements, camera state, and manifest.

### Changed
- **Manual Assist presents a whole-IRE target without rounding its calibration.**
  Match math retains the exact captured value (including the Log3G10 18% gray
  anchor at 33.333291 IRE); operator-facing target labels round to a whole IRE so
  a hand-set, non-click lens is not expected to land on a flickering decimal.
- **IRE matching now measures the approved ROI from the native 1920×1080 JPEG**
  while sphere detection, lock gates, and waveform diagnostics remain at the
  480-pixel analysis resolution.
- **Livestream quality is camera-advertised and read-back verified.** Array
  measurements require the same actual quality across every participant, and
  the focused-camera quality can no longer change during a measurement.
- **The view returns to multiview once the whole array is verified.** On a VERIFY
  PASS, Manual Assist drops out of the single-camera fullscreen feed back to the
  grid so the operator sees every tile confirmed at once.
- Rewrote `README.md` as a product-facing overview (removed internal
  phase/bench-spike framing and predecessor-project references).

### Fixed
- **Sphere detection no longer rejects real spheres at the shadow gate or the
  interior-std pre-filter.** Two measurement changes, no threshold constant
  touched. (1) `shadow_specular` split the sphere interior along the axis to its
  brightest *pixel*; on a mid-gray sphere carrying stream grain that pixel is
  noise, and the resulting ratio crossed the 0.96 and 0.985 bounds
  non-monotonically under small geometry error. The axis now comes from a
  least-squares plane fit to the interior luma, and the fitted slope — the shading
  strength, which is what says whether a terminator can carry information at all —
  is logged alongside the ratio. (2) Pre-filter G2/G3 measured interior std at
  full r, so a sphere sitting against a bright multiview pulled screen content
  into the statistic and was hard-rejected before any gate ran; it now measures at
  0.85r, clear of the limb transition. Measured over 13 KOMODO-X bench frames with
  detector-independent ground-truth ROIs: frames clearing both stages goes from
  8/13 to 13/13 at the primary bound, 10/13 to 13/13 including the `gating-2`
  escape hatch, and no frame needs that escape hatch any more. Full analysis and
  the offline harness are in `SPHERE_CLUE_FINDINGS.md`.
- **Bench evidence capture now fails closed across reconnects and export errors.**
  Capture preflight locks the camera and livestream generation before accepting
  JPEGs; stale URL-session callbacks, missing start/end rect read-backs, quality
  changes, and stream restarts cannot be certified. The trial CSV is regenerated
  atomically from manifest state so an export failure cannot leave a stale
  `complete` summary.
- **Capture Target & Start no longer rejects a fully-seeded array during a
  livestream flap.** The Manual Assist precondition check was a single
  instantaneous snapshot: if one camera happened to be mid-restart (auto-recover
  restarts and brief `The request timed out` drops are routine on a busy bench)
  at the exact moment the operator pressed the button, the whole capture was
  refused with "Start the livestream on every connected camera…" even though
  every sphere was seeded and solved. The check is now a bounded readiness wait
  (`manualReadyGrace`, 12 s): it polls until every connected camera is
  stream-live and holding a measurable sphere lock, exits as soon as the array
  is ready, and only fails — naming the specific cameras and reasons — if a
  camera never recovers within the window. `captureManualBaselines` was hardened
  the same way: it now exits early once every camera has its samples but tolerates
  a camera briefly mid-restart instead of aborting the calibration.

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
