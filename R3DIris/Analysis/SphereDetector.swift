//  SphereDetector.swift — R3DIris / Analysis
//  Gray-sphere auto-detection on live MJPEG frames.
//
//  Ported from R3DMatch v5's calibrated pipeline (src/r3dmatch3/sphere.py —
//  read-only reference; tuned thresholds carried over verbatim and cited).
//  Deliberate divergences from the R3DMatch original, each justified:
//
//  1. Candidate source: sphere.py's primary is cv2 HOUGH_GRADIENT_ALT
//     (gradient-direction-constrained voting). We implement the same idea
//     natively: edge pixels vote only along their own gradient direction, so
//     arc fragments / tape corners never accumulate a center. No OpenCV dep.
//  2. BRDF fallback gate (sphere.py G2b, brdf >= 0.28) is NOT ported. Its job
//     — rejecting phantoms in the mid-std band — is done here by temporal
//     persistence instead (SphereTracker: a candidate must re-detect in place
//     across consecutive live frames before it is trusted; phantoms flicker,
//     the real sphere doesn't move). Live video gives us this for free;
//     single-frame R3DMatch never had the option.
//  3. Input is the 8-bit display-referred livestream JPEG, not a REDline
//     scene-linear render. All thresholds that were calibrated on IPP2/BT.709
//     display renders (RGB ratios, std bands, IRE math) transfer, because
//     R3DMatch also gates in display space — but treat every number as
//     provisional until the Phase 2 bench re-validates on real stream frames.
//
//  Validated on live stream frames across the 2026-07-21 bench soaks
//  (IRIS_MATCH_NOTES.md); ported thresholds refined there (e.g. the ire_spread
//  probe geometry) and may still be tuned as more scenes are exercised.

import Foundation

// MARK: - Types

/// Sphere region in detection-buffer pixels.
struct SphereROI: Sendable, Equatable {
    var cx: Double
    var cy: Double
    var r: Double
}

struct SphereGateResult: Sendable {
    let gate: String
    let passed: Bool
    let value: Double
    let reason: String
}

/// Appearance signature of an operator-confirmed sphere, broadcast across the
/// array so other cameras auto-lock the matching object instead of the
/// top-vote Hough blob (e.g. flat carpet/tape). These are MATERIAL / VIEWPOINT
/// properties that transfer between cameras of the same physical sphere under
/// the same lighting — chromaticity (achromatic gray), interior texture,
/// angular size, and that a shadow terminator exists. Absolute POSITION does
/// NOT transfer (no array calibration), and the hero IRE VALUE legitimately
/// differs per camera (that difference is the exposure error being matched) —
/// so `heroIRE` is context only, never a target imposed on other cameras.
struct SphereSignature: Sendable, Equatable {
    var radiusRatio: Double     // r / normalizationWidth — angular-size prior
    var chroma: Double          // achromatic distance of the real sphere
    var interiorStd: Double     // interior luma std (texture) of the real sphere
    var shadowRatio: Double     // measured terminator strength (dark/bright)
    var lambertianOK: Bool      // seed passed the falloff expectation
    var heroIRE: Double?        // reference center IRE (context only, per docs)
}

struct SphereDetection: Sendable {
    enum Status: String, Sendable {
        case success          // full gate pipeline passed
        case successPass2     // passed with looser shadow gate (gating-2 analogue)
        case coasting         // detection failed this frame; measured at prior lock
        case failed
    }
    var status: Status
    var roi: SphereROI?           // detection-buffer px
    var heroIRE: Double?          // display-referred IRE at sphere hero center
    var gates: [SphereGateResult]
    var failureReason: String
    var bufferWidth: Int
    var bufferHeight: Int
    /// Diagnostics (populated by detect(), for the log): how many Hough
    /// candidates survived to the gate stage, and the strongest one's support.
    /// candidateCount == 0 means the Hough stage found nothing (not a gate
    /// rejection); candidateCount > 0 with status .failed means a gate rejected
    /// the best candidate — see `gates` for which one and its value.
    var candidateCount: Int = 0
    var topSupport: Double = 0
}

// MARK: - Detector

enum SphereDetector {

    // Tuned parameters — carried from R3DMatch sphere.py ("DO NOT CHANGE
    // without reason", handoff §5 there). Section comments cite the source.
    static let radiusMinRatio = 0.02      // _RADIUS_MIN_RATIO
    static let radiusMaxRatio = 0.32      // _RADIUS_MAX_RATIO (widened for 50mm+)
    static let pfRadiusMin = 0.018        // _PF_RADIUS_MIN — Hough noise floor
    static let pfStdCleanMax: Float = 0.020   // _PF_STD_CLEAN_MAX
    static let pfStdHardMax: Float = 0.130    // _PF_STD_HARD_MAX
    static let pfStdFloor: Float = 0.008      // _PF_STD_FLOOR
    static let pfRGMin: Float = 0.90          // _PF_RG_MIN
    static let pfRGMax: Float = 1.25
    static let pfBGMin: Float = 0.80
    static let pfBGMax: Float = 1.20
    static let gateChromaMaxDistance = 0.045  // _GATE_CHROMA_MAX_DISTANCE
    static let gateLambertianTolerance = 0.12 // _GATE_LAMBERTIAN_TOLERANCE
    static let gateIRESpreadMin = 0.8         // _GATE_IRE_SPREAD_MIN
    static let gateStddevMin: Float = 0.003   // _GATE_STDDEV_MIN
    static let gateStddevMax: Float = 0.170   // _GATE_STDDEV_MAX
    static let gateShadowRatioMax = 0.96      // _GATE_SHADOW_RATIO_MAX
    static let gateShadowRatioMaxPass2 = 0.985 // _GATE_SHADOW_RATIO_MAX_PASS2
    static let maxCandidates = 8

    /// Aspect-aware normalization width for sphere-size gates.
    ///
    /// The R3DMatch radius bands were calibrated on ~16:9 frames as r/WIDTH.
    /// The livestream mirrors whatever the monitor path carries — a 2.4:1 or
    /// letterboxed feed makes the same physical sphere a smaller fraction of
    /// WIDTH, silently shifting the calibrated band. Normalizing by the
    /// 16:9-equivalent width (min(w, h·16/9)) is identity on 16:9 — the
    /// calibration is untouched — and pins the band to frame HEIGHT on wider
    /// aspects, which is what actually bounds the sphere on set.
    ///
    /// NOT covered: anamorphic-squeezed streams render the sphere as an
    /// ellipse; circle detection is expected to fail there. Bench item —
    /// confirm the mirror output is desqueezed before relying on detection.
    static func normalizationWidth(width: Int, height: Int) -> Double {
        min(Double(width), Double(height) * 16.0 / 9.0)
    }

    /// Detect the gray sphere in one live frame.
    /// `prior` (from the tracker) narrows the radius search ±30% and prefers
    /// nearby candidates, mirroring sphere.py's profile-prior behavior.
    static func detect(in buf: PixelBuffer, prior: SphereROI?,
                       signature: SphereSignature? = nil) -> SphereDetection {
        let w = buf.width, h = buf.height
        let normW = normalizationWidth(width: w, height: h)
        var rMin = max(6, Int(normW * radiusMinRatio))
        var rMax = min(h / 2, Int(normW * radiusMaxRatio))

        if let prior {
            let lo = max(rMin, Int(prior.r * 0.70))
            let hi = min(rMax, Int(prior.r * 1.30))
            if lo < hi { rMin = lo; rMax = hi }
        } else if let sig = signature {
            // No tracker prior yet, but a hero seed told us the angular size —
            // narrow the radius band so a same-size sphere is preferred over an
            // arbitrary-size distractor (the carpet/tape latch).
            let target = sig.radiusRatio * normW
            let lo = max(rMin, Int(target * 0.70))
            let hi = min(rMax, Int(target * 1.30))
            if lo < hi { rMin = lo; rMax = hi }
        }
        guard rMin < rMax else {
            return failed("frame too small for radius search", buf)
        }

        var candidates = gradientHoughCandidates(buf: buf, rMin: rMin, rMax: rMax)
        if candidates.isEmpty {
            return failed("no circle candidates above threshold", buf)
        }
        // Diagnostics: how many circles the Hough stage proposed, and the best
        // support. Carried onto every result below so the log can separate
        // "Hough found nothing" from "a gate rejected the candidate".
        let candCount = candidates.count
        let topSup = candidates.map(\.support).max() ?? 0

        // Prefer candidates near the prior (sphere.py _prior_score analogue).
        if let prior {
            candidates.sort { a, b in
                score(a, prior: prior) < score(b, prior: prior)
            }
        } else {
            candidates.sort { $0.support > $1.support }
        }

        // Gate pipeline — first candidate that passes wins.
        var pass2Pool: [(Candidate, [SphereGateResult])] = []
        var lastFailedGates: [SphereGateResult] = []

        for cand in candidates.prefix(maxCandidates) {
            // Pre-filter G1 — radius floor (sphere.py _PF_RADIUS_MIN),
            // against the aspect-normalized width (see normalizationWidth).
            if cand.r / normW < pfRadiusMin { continue }

            // Pre-filter G2/G3 — interior std band.
            // Clean pass ≤ 0.020; mid band ≤ 0.130 admitted WITHOUT the BRDF
            // score (divergence #2 above: temporal persistence replaces it);
            // > 0.130 rejected unconditionally; < 0.008 is a flat phantom.
            let std = interiorStd(buf, cand.cx, cand.cy, cand.r)
            if std > pfStdHardMax || std < pfStdFloor { continue }

            // Pre-filter G4 — RGB ratio (kills colored objects)
            let (rg, bg) = rgbRatios(buf, cand.cx, cand.cy, cand.r)
            if !(pfRGMin...pfRGMax ~= rg && pfBGMin...pfBGMax ~= bg) { continue }

            var gates: [SphereGateResult] = []

            // Gate 1: Geometry — ratio vs 16:9-equivalent width (aspect-aware)
            let ratio = cand.r / normW
            let gGeom = SphereGateResult(
                gate: "geometry",
                passed: radiusMinRatio...radiusMaxRatio ~= ratio,
                value: ratio,
                reason: String(format: "r=%.1fpx ratio=%.3f", cand.r, ratio))
            gates.append(gGeom)
            if !gGeom.passed { lastFailedGates = gates; continue }

            // Gate 2: Gray Material — interior chromaticity distance
            let chroma = chromaticityDistance(buf, cand.cx, cand.cy, cand.r)
            let gGray = SphereGateResult(
                gate: "gray_material",
                passed: chroma <= gateChromaMaxDistance,
                value: chroma,
                reason: String(format: "chroma_dist=%.4f", chroma))
            gates.append(gGray)
            if !gGray.passed { lastFailedGates = gates; continue }

            // Gate 3: Lambertian — concentric-ring falloff
            let gLam = gateLambertian(buf, cand)
            gates.append(gLam)
            if !gLam.passed { lastFailedGates = gates; continue }

            // Gate 3.5: Shadow / Specular (convexity) — rejects flat charts
            let shadow = shadowRatio(buf, cand.cx, cand.cy, cand.r)
            let gShadow = SphereGateResult(
                gate: "shadow_specular",
                passed: shadow <= gateShadowRatioMax,
                value: shadow,
                reason: String(format: "shadow_ratio=%.4f", shadow))
            gates.append(gShadow)
            if !gShadow.passed {
                lastFailedGates = gates
                // Gating-2 analogue: our candidate source is gradient-
                // constrained (ALT-equivalent), so the looser bound is safe
                // per sphere.py's ALT-stream-only rule. Re-check later.
                if shadow <= gateShadowRatioMaxPass2 {
                    pass2Pool.append((cand, gates))
                }
                continue
            }

            // Gate 4: IRE Spread — bright/dark zone difference
            let spread = ireSpread(buf, cand.cx, cand.cy, cand.r)
            let gSpread = SphereGateResult(
                gate: "ire_spread",
                passed: spread >= gateIRESpreadMin,
                value: spread,
                reason: String(format: "spread=%.2f IRE", spread))
            gates.append(gSpread)
            if !gSpread.passed {
                // Signature waiver: on a stream whose shading is flattened
                // (low-Q JPEG, soak finding 2026-07-20) ire_spread collapses to
                // ~0 and rejects the real sphere. When a hero seed's signature
                // matches this candidate (achromatic, right texture + size, a
                // terminator present) we trust the operator-confirmed geometry
                // over the unreliable spread gate and let it through.
                let waived = signature.map { matchesSignature(buf, cand, $0, normW: normW) } ?? false
                if waived {
                    gates.append(SphereGateResult(
                        gate: "ire_spread_waived", passed: true, value: spread,
                        reason: "signature-matched; ire_spread unreliable on this stream"))
                } else {
                    lastFailedGates = gates
                    continue
                }
            }

            // Gate 5: Interior Stddev
            let std85 = interiorStd(buf, cand.cx, cand.cy, cand.r * 0.85)
            let gStd = SphereGateResult(
                gate: "interior_stddev",
                passed: gateStddevMin...gateStddevMax ~= std85,
                value: Double(std85),
                reason: String(format: "stddev=%.4f", std85))
            gates.append(gStd)
            if !gStd.passed { lastFailedGates = gates; continue }

            return finalize(cand, gates: gates, status: .success, buf,
                            candidateCount: candCount, topSupport: topSup)
        }

        // Gating-2 pass — evenly-lit spheres with no shadow terminator.
        for (cand, priorGates) in pass2Pool {
            var gates = priorGates
            let spread = ireSpread(buf, cand.cx, cand.cy, cand.r)
            let gSpread = SphereGateResult(gate: "ire_spread",
                                           passed: spread >= gateIRESpreadMin,
                                           value: spread,
                                           reason: String(format: "spread=%.2f IRE", spread))
            if !gSpread.passed {
                gates.append(gSpread)
                lastFailedGates = gates
                continue
            }
            let std85 = interiorStd(buf, cand.cx, cand.cy, cand.r * 0.85)
            let gStd = SphereGateResult(gate: "interior_stddev",
                                        passed: gateStddevMin...gateStddevMax ~= std85,
                                        value: Double(std85),
                                        reason: String(format: "stddev=%.4f", std85))
            if !gStd.passed {
                gates.append(gSpread)
                gates.append(gStd)
                lastFailedGates = gates
                continue
            }
            gates.append(SphereGateResult(gate: "shadow_specular_pass2", passed: true,
                                          value: priorGates.last(where: { $0.gate == "shadow_specular" })?.value ?? .nan,
                                          reason: "accepted at looser bound ≤0.985"))
            gates.append(gSpread)
            gates.append(gStd)
            return finalize(cand, gates: gates, status: .successPass2, buf,
                            candidateCount: candCount, topSupport: topSup)
        }

        return failed("all candidates failed gate pipeline", buf, gates: lastFailedGates,
                      candidateCount: candCount, topSupport: topSup)
    }

    /// Measure hero IRE at a known ROI without detection (tracker coasting,
    /// or a future manual-ROI path — same interface either way).
    static func measure(in buf: PixelBuffer, roi: SphereROI) -> Double? {
        heroIRE(buf, roi.cx, roi.cy, roi.r)
    }

    /// Extract a broadcastable appearance signature from an operator-confirmed
    /// ROI (the hero seed). Uses the same gate math the detector runs, so a
    /// matched candidate on another camera reads the same properties.
    static func profile(at roi: SphereROI, in buf: PixelBuffer) -> SphereSignature {
        let normW = normalizationWidth(width: buf.width, height: buf.height)
        let cand = Candidate(cx: roi.cx, cy: roi.cy, r: roi.r, support: 1.0)
        return SphereSignature(
            radiusRatio: roi.r / normW,
            chroma: chromaticityDistance(buf, roi.cx, roi.cy, roi.r),
            interiorStd: Double(interiorStd(buf, roi.cx, roi.cy, roi.r * 0.85)),
            shadowRatio: shadowRatio(buf, roi.cx, roi.cy, roi.r),
            lambertianOK: gateLambertian(buf, cand).passed,
            heroIRE: heroIRE(buf, roi.cx, roi.cy, roi.r))
    }

    /// Does `cand` look like the seeded sphere? Material + geometry only —
    /// achromatic, in-band texture, same angular size, and a terminator at
    /// least as convex as the seed's. Deliberately excludes ire_spread (the
    /// gate the signature exists to waive) and position (doesn't transfer).
    private static func matchesSignature(_ buf: PixelBuffer, _ cand: Candidate,
                                         _ sig: SphereSignature, normW: Double) -> Bool {
        let ratio = cand.r / normW
        guard abs(ratio - sig.radiusRatio) <= 0.30 * max(sig.radiusRatio, 0.02) + 0.01 else { return false }
        let chroma = chromaticityDistance(buf, cand.cx, cand.cy, cand.r)
        guard chroma <= max(gateChromaMaxDistance, sig.chroma * 1.5) else { return false }
        let std = interiorStd(buf, cand.cx, cand.cy, cand.r * 0.85)
        guard gateStddevMin...gateStddevMax ~= std else { return false }
        // A real sphere has a shadow terminator; the flat carpet/tape distractor
        // does not (shadow_ratio ~1). Require convexity no flatter than the seed.
        let shadow = shadowRatio(buf, cand.cx, cand.cy, cand.r)
        guard shadow <= gateShadowRatioMaxPass2 else { return false }
        return true
    }

    // MARK: - Candidate generation (gradient-direction-constrained Hough)

    struct Candidate: Sendable {
        var cx: Double
        var cy: Double
        var r: Double
        var support: Double   // radially-aligned edge support, normalized by circumference
    }

    private static func score(_ c: Candidate, prior: SphereROI) -> Double {
        // sphere.py _prior_score: distance − accumulator·20 (lower = better)
        let dist = hypot(c.cx - prior.cx, c.cy - prior.cy)
        return dist - c.support * 20
    }

    private static func gradientHoughCandidates(buf: PixelBuffer, rMin: Int, rMax: Int) -> [Candidate] {
        let w = buf.width, h = buf.height
        let luma = buf.luma

        // Sobel gradients
        var gx = [Float](repeating: 0, count: w * h)
        var gy = [Float](repeating: 0, count: w * h)
        var mag = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let a = luma[i - w - 1], b = luma[i - w], c = luma[i - w + 1]
                let d = luma[i - 1],                     e = luma[i + 1]
                let f = luma[i + w - 1], g = luma[i + w], k = luma[i + w + 1]
                let sx = (c + 2 * e + k) - (a + 2 * d + f)
                let sy = (f + 2 * g + k) - (a + 2 * b + c)
                gx[i] = sx; gy[i] = sy
                mag[i] = sqrt(sx * sx + sy * sy)
            }
        }

        // Adaptive edge threshold: 92nd percentile with a floor. The sphere
        // boundary in _106-type gray-on-gray scenes is weak — keep the floor low.
        let sortedSample = stride(from: 0, to: mag.count, by: 7).map { mag[$0] }.sorted()
        let p92 = sortedSample.isEmpty ? 0.05 : sortedSample[Int(Double(sortedSample.count) * 0.92)]
        let threshold = max(0.03, p92)

        // Vote: each edge pixel votes for centers along ±its gradient
        // direction at distances rMin…rMax (the HOUGH_GRADIENT_ALT idea —
        // arc fragments with inconsistent gradients never pile up).
        var acc = [Int32](repeating: 0, count: w * h)
        var edgeIdx: [Int32] = []
        edgeIdx.reserveCapacity(8192)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard mag[i] >= threshold else { continue }
                edgeIdx.append(Int32(i))
                let inv = 1.0 / mag[i]
                let ux = gx[i] * inv, uy = gy[i] * inv
                var d = rMin
                while d <= rMax {
                    let fd = Float(d)
                    for s: Float in [1, -1] {
                        let cx = x + Int((s * ux * fd).rounded())
                        let cy = y + Int((s * uy * fd).rounded())
                        if cx >= 0 && cx < w && cy >= 0 && cy < h {
                            acc[cy * w + cx] += 1
                        }
                    }
                    d += 1
                }
            }
        }

        // Peak extraction with non-max suppression at rMin spacing.
        var peaks: [(x: Int, y: Int, votes: Int32)] = []
        var accCopy = acc
        for _ in 0..<maxCandidates {
            var best: Int32 = 0
            var bestIdx = -1
            for i in 0..<accCopy.count where accCopy[i] > best {
                best = accCopy[i]; bestIdx = i
            }
            guard bestIdx >= 0, best >= Int32(max(8, rMin)) else { break }
            let px = bestIdx % w, py = bestIdx / w
            peaks.append((px, py, best))
            let clear = rMin
            for yy in max(0, py - clear)...min(h - 1, py + clear) {
                for xx in max(0, px - clear)...min(w - 1, px + clear) {
                    accCopy[yy * w + xx] = 0
                }
            }
        }

        // Radius estimation per peak: modal distance of radially-aligned edges.
        var out: [Candidate] = []
        for peak in peaks {
            var hist = [Int](repeating: 0, count: rMax + 2)
            for ei in edgeIdx {
                let i = Int(ei)
                let ex = i % w, ey = i / w
                let dx = Double(ex - peak.x), dy = Double(ey - peak.y)
                let dist = (dx * dx + dy * dy).squareRoot()
                guard dist >= Double(rMin), dist <= Double(rMax), dist > 0.5 else { continue }
                // Radial alignment: gradient must point along the center↔edge axis.
                let inv = 1.0 / Double(mag[i])
                let ux = Double(gx[i]) * inv, uy = Double(gy[i]) * inv
                let rx = dx / dist, ry = dy / dist
                if abs(ux * rx + uy * ry) >= 0.85 {
                    hist[Int(dist.rounded())] += 1
                }
            }
            var bestR = 0, bestCount = 0
            for r in rMin...rMax {
                // Sum a ±1 window so quantization doesn't split the mode.
                let c = hist[r] + (r > 0 ? hist[r - 1] : 0) + hist[r + 1]
                if c > bestCount { bestCount = c; bestR = r }
            }
            guard bestR > 0 else { continue }
            let support = Double(bestCount) / (2.0 * Double.pi * Double(bestR))
            // Require ~12% of the circumference to be radially-aligned edge —
            // below that it's accumulator coincidence, not a circle.
            if support >= 0.12 {
                out.append(Candidate(cx: Double(peak.x), cy: Double(peak.y),
                                     r: Double(bestR), support: min(support, 1.0)))
            }
        }
        return out
    }

    // MARK: - Gate math (direct ports from sphere.py)

    /// Interior luma stddev within radius r (sphere.py _interior_mask + std).
    private static func interiorStd(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ r: Double) -> Float {
        var sum: Double = 0, sumSq: Double = 0, n = 0
        forEachDiskPixel(buf, cx, cy, r) { i in
            let v = Double(buf.luma[i]); sum += v; sumSq += v * v; n += 1
        }
        guard n >= 20 else { return 1.0 }
        let mean = sum / Double(n)
        let variance = max(0, sumSq / Double(n) - mean * mean)
        return Float(variance.squareRoot())
    }

    /// Mean R/G and B/G ratios inside the candidate (sphere.py pre-filter G4).
    private static func rgbRatios(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ r: Double) -> (Float, Float) {
        var sr: Double = 0, sg: Double = 0, sb: Double = 0, n = 0
        forEachDiskPixel(buf, cx, cy, r) { i in
            sr += Double(buf.r[i]); sg += Double(buf.g[i]); sb += Double(buf.b[i]); n += 1
        }
        guard n > 0, sg > 1e-9 else { return (99, 99) }
        return (Float(sr / sg), Float(sb / sg))
    }

    /// Chromaticity distance from achromatic at 0.70r (sphere.py _chromaticity_distance).
    private static func chromaticityDistance(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
        var sr: Double = 0, sg: Double = 0, sb: Double = 0, n = 0
        forEachDiskPixel(buf, cx, cy, r * 0.70) { i in
            sr += Double(buf.r[i]); sg += Double(buf.g[i]); sb += Double(buf.b[i]); n += 1
        }
        guard n >= 10 else { return 999 }
        let total = sr + sg + sb
        guard total > 1e-6 else { return 999 }
        let rc = sr / total, gc = sg / total
        return hypot(rc - 1.0 / 3.0, gc - 1.0 / 3.0)
    }

    /// Lambertian falloff gate: 4 rings at 0.20/0.45/0.68/0.80 r, half-width
    /// 0.06r, each outer ring ≤ inner × 1.12 (sphere.py _gate_lambertian;
    /// outermost tightened to 0.80r per Session 13).
    private static func gateLambertian(_ buf: PixelBuffer, _ cand: Candidate) -> SphereGateResult {
        let ringRadii = [0.20, 0.45, 0.68, 0.80].map { $0 * cand.r }
        var ringLum: [Double?] = []
        for rr in ringRadii {
            ringLum.append(ringLuminance(buf, cand.cx, cand.cy, rr, halfWidth: 0.06 * cand.r))
        }
        var violations = 0
        for i in 0..<(ringLum.count - 1) {
            guard let inner = ringLum[i], let outer = ringLum[i + 1] else { continue }
            if outer > inner * (1 + gateLambertianTolerance) { violations += 1 }
        }
        return SphereGateResult(
            gate: "lambertian",
            passed: violations == 0,
            value: Double(violations),
            reason: "violations=\(violations)")
    }

    private static func ringLuminance(_ buf: PixelBuffer, _ cx: Double, _ cy: Double,
                                      _ ringR: Double, halfWidth: Double) -> Double? {
        var sum: Double = 0, n = 0
        let outer = ringR + halfWidth
        let x0 = max(0, Int(cx - outer)), x1 = min(buf.width - 1, Int(cx + outer) + 1)
        let y0 = max(0, Int(cy - outer)), y1 = min(buf.height - 1, Int(cy + outer) + 1)
        guard x0 <= x1, y0 <= y1 else { return nil }
        for y in y0...y1 {
            for x in x0...x1 {
                let d = hypot(Double(x) - cx, Double(y) - cy)
                if d >= ringR - halfWidth && d <= ringR + halfWidth {
                    sum += Double(buf.luma[y * buf.width + x]); n += 1
                }
            }
        }
        return n >= 4 ? sum / Double(n) : nil
    }

    /// Shadow ratio at 0.7r: dark-half mean / bright-half mean, split along the
    /// center→peak-luminance axis (sphere.py _gate_shadow_specular; peak_excess
    /// is diagnostic-only there and omitted here).
    private static func shadowRatio(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
        var peakLum: Float = -1
        var peakX = 0, peakY = 0
        var interior: [(x: Int, y: Int, lum: Float)] = []
        forEachDiskPixelXY(buf, cx, cy, r * 0.7) { x, y, i in
            let v = buf.luma[i]
            interior.append((x, y, v))
            if v > peakLum { peakLum = v; peakX = x; peakY = y }
        }
        guard interior.count >= 20 else { return 0.0 }  // too few pixels — pass (sphere.py behavior)

        var dx = Double(peakX) - cx, dy = Double(peakY) - cy
        let norm = hypot(dx, dy)
        if norm > 1.0 { dx /= norm; dy /= norm } else { dx = 1; dy = 0 }

        var brightSum: Double = 0, brightN = 0
        var darkSum: Double = 0, darkN = 0
        for p in interior {
            let proj = (Double(p.x) - cx) * dx + (Double(p.y) - cy) * dy
            if proj >= 0 { brightSum += Double(p.lum); brightN += 1 }
            else { darkSum += Double(p.lum); darkN += 1 }
        }
        let brightMean = brightN > 0 ? brightSum / Double(brightN) : 0
        let darkMean = darkN > 0 ? darkSum / Double(darkN) : 0
        return darkMean / max(brightMean, 1e-6)
    }

    /// Hero IRE probe: disk 0.24r at center, drop zeros, 5–95 percentile trim,
    /// median × 100 (sphere.py _probe_hero_ire — its log2/exp2 round-trip on the
    /// median is an identity, so the port takes the median directly).
    static func heroIRE(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ r: Double) -> Double? {
        var vals: [Float] = []
        forEachDiskPixel(buf, cx, cy, r * 0.24) { i in
            let v = buf.luma[i]
            if v > 0 { vals.append(v) }
        }
        guard vals.count >= 4 else { return nil }
        vals.sort()
        let lo = Int(Double(vals.count) * 0.05)
        let hi = max(lo + 1, Int(Double(vals.count) * 0.95))
        let trimmed = Array(vals[lo..<min(hi, vals.count)])
        guard !trimmed.isEmpty else { return nil }
        let median = Double(trimmed[trimmed.count / 2])
        return median * 100.0
    }

    /// Bright/dark zone IRE difference (sphere.py _compute_ire_spread).
    ///
    /// The R3DMatch probe geometry samples disks of radius 0.24·(0.20r) ≈ 0.048r.
    /// On R3DMatch's full-res renders the sphere is large, so that's several
    /// pixels; on the downscaled livestream the sphere is ~16–18px, making the
    /// probe SUB-PIXEL (~0.8px) — heroIRE can't gather its ≥4 samples, returns
    /// nil, and the spread reads a structural 0. That rejected the real sphere
    /// 1424× (100% of ire_spread failures were exactly 0.00) in the 2026-07-21
    /// soak. Fix is measurability, NOT threshold: floor the probe to stay multi-
    /// pixel and widen the offset so the two halves stay separated. A genuinely
    /// flat chart still reads ~0 and is still rejected by the ≥0.8 gate.
    private static func ireSpread(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
        let offset = max(3.0, 0.30 * r)
        let probeR = max(2.5, 0.15 * r)
        guard let bright = zoneMedianIRE(buf, cx + offset, cy, probeR),
              let dark = zoneMedianIRE(buf, cx - offset, cy, probeR) else { return 0 }
        return abs(bright - dark)
    }

    /// Median IRE (×100) over a disk of the given PIXEL radius; drops zeros and
    /// needs ≥4 samples. Direct-radius sibling of heroIRE (which scales by 0.24),
    /// used where a pixel-floored probe matters on small livestream spheres.
    private static func zoneMedianIRE(_ buf: PixelBuffer, _ cx: Double, _ cy: Double, _ pr: Double) -> Double? {
        var vals: [Float] = []
        forEachDiskPixel(buf, cx, cy, pr) { i in
            let v = buf.luma[i]
            if v > 0 { vals.append(v) }
        }
        guard vals.count >= 4 else { return nil }
        vals.sort()
        return Double(vals[vals.count / 2]) * 100.0
    }

    // MARK: - Pixel iteration helpers

    private static func forEachDiskPixel(_ buf: PixelBuffer, _ cx: Double, _ cy: Double,
                                         _ r: Double, _ body: (Int) -> Void) {
        forEachDiskPixelXY(buf, cx, cy, r) { _, _, i in body(i) }
    }

    private static func forEachDiskPixelXY(_ buf: PixelBuffer, _ cx: Double, _ cy: Double,
                                           _ r: Double, _ body: (Int, Int, Int) -> Void) {
        let x0 = max(0, Int(cx - r)), x1 = min(buf.width - 1, Int(cx + r) + 1)
        let y0 = max(0, Int(cy - r)), y1 = min(buf.height - 1, Int(cy + r) + 1)
        guard x0 <= x1, y0 <= y1 else { return }
        let r2 = r * r
        for y in y0...y1 {
            let dy = Double(y) - cy
            for x in x0...x1 {
                let dx = Double(x) - cx
                if dx * dx + dy * dy <= r2 {
                    body(x, y, y * buf.width + x)
                }
            }
        }
    }

    // MARK: - Result builders

    private static func finalize(_ cand: Candidate, gates: [SphereGateResult],
                                 status: SphereDetection.Status, _ buf: PixelBuffer,
                                 candidateCount: Int = 0, topSupport: Double = 0) -> SphereDetection {
        // Limb-snap: the Hough center drifts toward the LIT side whenever the
        // shadow-side limb fades into a dark backdrop (half the boundary casts
        // no votes) — the classic symptom is a small circle hugging the
        // specular lobe and a hero IRE read off the highlight. Refining
        // against the actual luma limb fixes both position and measurement.
        let roi = refineToLimb(SphereROI(cx: cand.cx, cy: cand.cy, r: cand.r), in: buf)
        return SphereDetection(
            status: status, roi: roi,
            heroIRE: heroIRE(buf, roi.cx, roi.cy, roi.r),
            gates: gates, failureReason: "",
            bufferWidth: buf.width, bufferHeight: buf.height,
            candidateCount: candidateCount, topSupport: topSupport)
    }

    // MARK: - Limb-snap refinement
    //
    // Cast rays from the candidate center; on each ray find the strongest
    // luma-gradient crossing inside an annulus around the candidate radius
    // (that's the limb, wherever it has ANY contrast), then least-squares fit
    // a circle (Kåsa) to the hit points with one 25%-trim pass. Rays that
    // cross no meaningful gradient (shadow limb into black) simply don't
    // vote — the fit uses whatever arc is real instead of hallucinating.

    static let refineRayCount = 48
    static let refineMinHits = 10
    static let refineGradFloor: Float = 0.015   // per-px luma step at the limb
    /// Per-iteration movement cap as a fraction of r — anti-teleport. A fit
    /// farther away than this is APPROACHED in bounded steps across the
    /// iterations, not rejected (validated 2026-07-17: converges from a
    /// 0.4r-off, 30%-undersized init to 0.5 px of ground truth in 4 steps).
    static let refineMaxShift = 0.35

    static func refineToLimb(_ initial: SphereROI, in buf: PixelBuffer, iterations: Int = 4) -> SphereROI {
        var roi = initial
        for _ in 0..<iterations {
            var pts: [(Double, Double, Double)] = []   // x, y, |grad| weight
            let r0 = roi.r * 0.55, r1 = roi.r * 1.45
            for k in 0..<refineRayCount {
                let ang = Double(k) * 2.0 * .pi / Double(refineRayCount)
                let ux = cos(ang), uy = sin(ang)
                var bestMag: Float = 0
                var bestT = -1.0
                var prev: Float? = nil
                var t = r0
                while t <= r1 {
                    let x = Int((roi.cx + ux * t).rounded())
                    let y = Int((roi.cy + uy * t).rounded())
                    guard x >= 0, x < buf.width, y >= 0, y < buf.height else { break }
                    let v = buf.luma[y * buf.width + x]
                    if let p = prev {
                        let mag = abs(v - p)
                        if mag > bestMag { bestMag = mag; bestT = t - 0.5 }
                    }
                    prev = v
                    t += 1.0
                }
                if bestMag >= refineGradFloor, bestT > 0 {
                    pts.append((roi.cx + ux * bestT, roi.cy + uy * bestT, Double(bestMag)))
                }
            }
            guard pts.count >= refineMinHits,
                  var fit = kasaFit(pts) else { return roi }
            // One robust trim: drop the worst quarter by radial residual, refit.
            let residuals = pts.map { p in
                abs(hypot(p.0 - fit.cx, p.1 - fit.cy) - fit.r)
            }
            let cutoff = residuals.sorted()[residuals.count * 3 / 4]
            let kept = zip(pts, residuals).filter { $0.1 <= cutoff }.map(\.0)
            if kept.count >= refineMinHits, let refit = kasaFit(kept) {
                fit = refit
            }
            // Sanity: a radius that balloons or collapses is a bad fit.
            guard fit.r >= roi.r * 0.6, fit.r <= roi.r * 1.6, fit.r >= 4 else { return roi }
            // Anti-teleport: move TOWARD a distant fit in bounded steps
            // rather than rejecting it — converges from poor initializations
            // while a single frame still can't yank the lock across the frame.
            let shift = hypot(fit.cx - roi.cx, fit.cy - roi.cy)
            let maxStep = roi.r * refineMaxShift
            if shift > maxStep {
                let s = maxStep / shift
                roi = SphereROI(cx: roi.cx + (fit.cx - roi.cx) * s,
                                cy: roi.cy + (fit.cy - roi.cy) * s,
                                r: roi.r + (fit.r - roi.r) * s)
            } else {
                roi = SphereROI(cx: fit.cx, cy: fit.cy, r: fit.r)
            }
        }
        return roi
    }

    /// Kåsa algebraic circle fit: minimize Σ(x²+y²+Dx+Ey+F)². Weighted by
    /// gradient magnitude so strong limb points dominate faint ones.
    private static func kasaFit(_ pts: [(Double, Double, Double)]) -> (cx: Double, cy: Double, r: Double)? {
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, sw = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        for (x, y, w) in pts {
            let z = x * x + y * y
            sxx += w * x * x; sxy += w * x * y; syy += w * y * y
            sx += w * x; sy += w * y; sw += w
            sxz += w * x * z; syz += w * y * z; sz += w * z
        }
        guard sw > 0 else { return nil }
        // Normal equations for [D, E, F]:
        //   [sxx sxy sx][D]   [-sxz]
        //   [sxy syy sy][E] = [-syz]
        //   [sx  sy  sw][F]   [-sz ]
        var m = [[sxx, sxy, sx, -sxz],
                 [sxy, syy, sy, -syz],
                 [sx, sy, sw, -sz]]
        // Gaussian elimination with partial pivoting.
        for col in 0..<3 {
            var pivot = col
            for row in (col + 1)..<3 where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            if abs(m[pivot][col]) < 1e-12 { return nil }
            m.swapAt(col, pivot)
            let div = m[col][col]
            for j in col..<4 { m[col][j] /= div }
            for row in 0..<3 where row != col {
                let factor = m[row][col]
                if factor != 0 {
                    for j in col..<4 { m[row][j] -= factor * m[col][j] }
                }
            }
        }
        let d = m[0][3], e = m[1][3], f = m[2][3]
        let cx = -d / 2, cy = -e / 2
        let r2 = cx * cx + cy * cy - f
        guard r2 > 0 else { return nil }
        return (cx, cy, r2.squareRoot())
    }

    private static func failed(_ reason: String, _ buf: PixelBuffer,
                               gates: [SphereGateResult] = [],
                               candidateCount: Int = 0, topSupport: Double = 0) -> SphereDetection {
        SphereDetection(status: .failed, roi: nil, heroIRE: nil, gates: gates,
                        failureReason: reason,
                        bufferWidth: buf.width, bufferHeight: buf.height,
                        candidateCount: candidateCount, topSupport: topSupport)
    }
}
