//  SphereTracker.swift — R3DIris / Analysis
//  Temporal persistence over per-frame detections, plus the luma waveform grid.
//
//  The tracker is the live-video replacement for R3DMatch's BRDF fallback gate
//  (see SphereDetector.swift divergence #2): a candidate must re-detect in
//  place across consecutive frames before it is trusted as the measurement
//  target. Once locked, a frame with no detection COASTS — the sphere is
//  static on a volumetric stage, so we keep measuring at the locked ROI and
//  count misses; sustained misses (occlusion, reframe) drop the lock.

import Foundation

/// Normalized-coordinate sphere state published to the UI and the match loop.
struct SphereState: Sendable, Equatable {
    enum Phase: String, Sendable {
        case searching      // no candidate yet
        case candidate      // detected, not yet persistent
        case locked         // persistent — trusted for the match loop
        case coasting       // locked, but the last frame(s) failed to re-detect
    }
    var phase: Phase = .searching
    /// ROI in NORMALIZED [0,1] frame coordinates (x/width, y/height, r/width).
    var cx: Double = 0
    var cy: Double = 0
    var r: Double = 0
    var heroIRE: Double? = nil
    var measuredAt: Date? = nil
    var detail: String = ""
    /// Operator-seeded lock (click-to-seed). A human confirmed the sphere, so
    /// the track is not dropped on detection misses — it coasts indefinitely,
    /// measuring at the seeded ROI, until an explicit re-detect or a new seed.
    var seeded: Bool = false

    var hasROI: Bool { phase == .locked || phase == .coasting || phase == .candidate }
    /// The loop only trusts a locked (or briefly coasting) sphere.
    var measurable: Bool { (phase == .locked || phase == .coasting) && heroIRE != nil }
}

/// Not @MainActor — owned by CameraNode, mutated only on the main actor via
/// the node's analysis completion path.
struct SphereTracker {
    // Persistence tuning (live-loop values; revisit on the bench):
    // 3 consecutive in-place hits to lock ≈ 1 s at the 3 Hz analysis cadence.
    static let hitsToLock = 3
    static let missesToUnlock = 10       // ≈3 s of continuous failure drops the lock
    static let matchDistanceRatio = 0.5  // new det within 0.5·r of lock = same sphere
    /// EMA weight for in-place re-detections. The sphere is static on a
    /// volumetric stage — per-frame detection scatter (JPEG noise, integer
    /// Hough cells) is measurement noise, not motion, so the displayed/
    /// measured ROI converges instead of wandering. Real drift still tracks
    /// (~1 s to close 70% of a move at 3 Hz); a JUMP past the match distance
    /// resets hard and re-confirms, so reframes aren't smoothed away.
    static let smoothing = 0.30

    private(set) var state = SphereState()
    private var hits = 0
    private var misses = 0

    /// Fold one frame's detection into the track. Detection ROI arrives in
    /// buffer pixels; normalize by the buffer dims before storing.
    mutating func update(with det: SphereDetection) {
        let w = Double(det.bufferWidth), h = Double(det.bufferHeight)
        guard w > 0, h > 0 else { return }

        switch det.status {
        case .success, .successPass2:
            guard let roi = det.roi else { return }
            let nx = roi.cx / w, ny = roi.cy / h, nr = roi.r / w
            let near = state.hasROI &&
                hypot(nx - state.cx, ny - state.cy) <= state.r * Self.matchDistanceRatio

            // An operator-approved lock is FROZEN: the human placed and sized
            // it, so no detection — near or far — moves its geometry. Refresh
            // the hero measurement only and stay locked (no EMA drift).
            if state.seeded {
                misses = 0
                state.phase = .locked
                state.heroIRE = det.heroIRE ?? state.heroIRE
                if det.heroIRE != nil { state.measuredAt = Date() }
                state.detail = "locked (operator seed)"
                return
            }

            if near || !state.hasROI {
                hits = near ? hits + 1 : 1
            } else {
                hits = 1    // sphere (or detection) jumped — restart persistence
            }
            misses = 0
            if near {
                // In-place re-detection: blend, don't replace (see `smoothing`).
                let a = Self.smoothing
                state.cx += (nx - state.cx) * a
                state.cy += (ny - state.cy) * a
                state.r += (nr - state.r) * a
            } else {
                state.cx = nx; state.cy = ny; state.r = nr
            }
            state.heroIRE = det.heroIRE
            state.measuredAt = Date()
            if hits >= Self.hitsToLock {
                state.phase = .locked
                state.detail = det.status == .successPass2 ? "locked (gating-2)" : "locked"
            } else {
                state.phase = .candidate
                state.detail = "confirming \(hits)/\(Self.hitsToLock)"
            }

        case .coasting:
            // Detection failed (or was skipped) but the caller measured at the
            // locked ROI.
            if state.phase == .locked || state.phase == .coasting {
                if state.seeded {
                    // Frozen operator lock: refresh the measurement, stay locked
                    // at the fixed ROI, never time out.
                    misses = 0
                    state.phase = .locked
                    state.heroIRE = det.heroIRE ?? state.heroIRE
                    if det.heroIRE != nil { state.measuredAt = Date() }
                    state.detail = "locked (operator seed)"
                } else {
                    misses += 1
                    state.phase = misses >= Self.missesToUnlock ? .searching : .coasting
                    if state.phase == .searching {
                        reset(detail: "lock lost (\(misses) misses)")
                    } else {
                        state.heroIRE = det.heroIRE ?? state.heroIRE
                        if det.heroIRE != nil { state.measuredAt = Date() }
                        state.detail = "coasting (\(misses))"
                    }
                }
            }

        case .failed:
            switch state.phase {
            case .locked, .coasting:
                if state.seeded {
                    state.phase = .locked
                    state.detail = "locked (operator seed)"
                } else {
                    misses += 1
                    if misses >= Self.missesToUnlock {
                        reset(detail: "lock lost (\(misses) misses)")
                    } else {
                        state.phase = .coasting
                        state.detail = "coasting (\(misses))"
                    }
                }
            case .candidate:
                reset(detail: det.failureReason)
            case .searching:
                state.detail = det.failureReason
            }
        }
    }

    /// The ROI to hand the detector as a prior (in buffer px for a given size),
    /// or nil when there is nothing worth narrowing the search with.
    func prior(forBufferWidth w: Int, height h: Int) -> SphereROI? {
        guard state.hasROI else { return nil }
        return SphereROI(cx: state.cx * Double(w),
                         cy: state.cy * Double(h),
                         r: state.r * Double(w))
    }

    /// Force a locked track from an operator click-to-seed (normalized coords).
    /// The human is the confirmation the 3-consecutive-hit persistence gate was
    /// standing in for, so this bypasses temporal persistence entirely and the
    /// lock then holds through detection misses (see `seeded`).
    mutating func manualLock(cx: Double, cy: Double, r: Double, heroIRE: Double?) {
        hits = Self.hitsToLock
        misses = 0
        state.phase = .locked
        state.cx = cx
        state.cy = cy
        state.r = r
        state.heroIRE = heroIRE
        state.measuredAt = Date()
        state.seeded = true
        state.detail = "locked (operator seed)"
    }

    /// Promote the current auto-lock to a FROZEN (operator-equivalent) lock so a
    /// deliberate monitor-transform swap can't unlock the mask via appearance
    /// gates. On the flat/desaturated Log3G10 look, Hough detection fails and a
    /// non-seeded track coasts, then times out (~3 s); the sphere never moved, so
    /// freeze it in place and keep measuring hero IRE at the fixed ROI. Returns
    /// true only if this call newly froze the track, so the caller can reverse it
    /// (an already-seeded operator lock is left untouched and not reported).
    @discardableResult
    mutating func freezeAtCurrentLock() -> Bool {
        guard state.phase == .locked || state.phase == .coasting, !state.seeded else { return false }
        misses = 0
        state.phase = .locked
        state.seeded = true
        state.detail = "locked (frozen for transform)"
        return true
    }

    /// Reverse freezeAtCurrentLock(): drop back to normal persistence tracking
    /// while staying locked. No-op if the track isn't frozen.
    mutating func unfreeze() {
        guard state.seeded else { return }
        state.seeded = false
        hits = Self.hitsToLock
        misses = 0
        state.detail = "locked"
    }

    mutating func reset(detail: String = "") {
        hits = 0
        misses = 0
        state = SphereState()
        state.detail = detail
    }
}

// MARK: - Waveform

/// Luma waveform: columns × levels intensity grid, rendered by WaveformView.
/// Column = horizontal position in frame; row 0 = level 0 (black) at the
/// BOTTOM when drawn. Values are hit counts normalized to [0,1] per column.
struct WaveformGrid: Sendable, Equatable {
    static let columns = 128
    static let levels = 64

    var intensity: [Float]   // columns × levels, index = col * levels + level

    static func compute(from buf: PixelBuffer) -> WaveformGrid {
        var counts = [Float](repeating: 0, count: columns * levels)
        let w = buf.width, h = buf.height
        guard w > 0, h > 0 else { return WaveformGrid(intensity: counts) }
        for y in 0..<h {
            for x in 0..<w {
                let col = min(columns - 1, x * columns / w)
                let v = buf.luma[y * w + x]
                let level = min(levels - 1, max(0, Int(v * Float(levels))))
                counts[col * levels + level] += 1
            }
        }
        // Normalize per column so exposure reads as position, not density.
        for c in 0..<columns {
            var maxV: Float = 0
            for l in 0..<levels { maxV = max(maxV, counts[c * levels + l]) }
            if maxV > 0 {
                for l in 0..<levels { counts[c * levels + l] /= maxV }
            }
        }
        return WaveformGrid(intensity: counts)
    }
}
