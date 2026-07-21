//  CameraNode.swift — R3DIris / Array (Phase 2)
//  One camera in the array: RCP2 session (CameraActor, unchanged transport) +
//  livestream + throttled sphere analysis. All UI-observable state lives here.
//
//  Field-notes compliance: one CameraActor = one WS session per body (rule 2);
//  the livestream is plain HTTP on :9090 and costs no session slot.

import Foundation
import CoreGraphics

@MainActor
final class CameraNode: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let ip: String

    @Published private(set) var status = CameraStatus()
    @Published private(set) var sphere = SphereState()
    @Published private(set) var waveform: WaveformGrid? = nil
    /// Frozen-stream watchdog: the livestream has stopped changing while
    /// streaming (the silent mid-soak degradation, 2026-07-20). UI-visible.
    @Published private(set) var streamStale = false
    /// Operator is placing/sizing a sphere mask (click-to-seed): a candidate
    /// ROI shown with a resize slider and center sample, not yet locked or
    /// broadcast. nil once approved or cancelled.
    @Published var pendingSeed: PendingSeed?

    /// Human label: the operator-assigned CAMERA_ID ("GA"), else IP.
    var displayName: String { status.displayID.isEmpty ? ip : status.displayID }
    /// Match-loop bookkeeping, published for the per-camera delta readout.
    @Published var match = NodeMatchInfo()
    /// Manual Assist bookkeeping. This never drives RCP2 aperture commands;
    /// it is live operator guidance derived from the sphere measurement.
    @Published var manualMatch = ManualMatchInfo()

    let stream = MJPEGStreamReader()
    private(set) var camera: CameraActor?
    private var tracker = SphereTracker()
    private weak var soakRecorder: SoakRecorder?

    /// Hero-seed signature broadcast to this camera — biases the detector
    /// toward the matching sphere and kills the flat-distractor latch. nil
    /// until a hero camera is seeded.
    private var seedSignature: SphereSignature?

    /// Livestream JPEG quality applied on stream start. Q100 default — low-Q
    /// flattens the sphere shading and collapses ire_spread (soak 2026-07-20).
    var desiredQuality = 4

    // Frozen-stream watchdog bookkeeping.
    static let freezeGrace: TimeInterval = 2.5
    private var lastFingerprint: UInt64 = 0
    private var frozenSince: Date?

    /// Analysis cadence — ~3 Hz keeps 12–40 nodes cheap; the auto loop's
    /// debounce dominates its responsiveness anyway (handoff §8).
    /// Manual trimming is different: a human is inside the feedback loop, so
    /// participants get a fast path (~6.7 Hz) to cut measurement latency —
    /// that delay is what forces slow iris movements.
    static let analysisInterval: TimeInterval = 0.33
    static let fastAnalysisInterval: TimeInterval = 0.15
    /// The focused camera during a trim is FROZEN (seeded → detection skipped, so
    /// each pass is just a cheap hero-IRE sample at the fixed ROI). That lets us
    /// sample ~14 Hz on the one camera a hand is on without the Hough cost —
    /// directly cutting the feedback latency that forces slow iris moves.
    static let frozenAnalysisInterval: TimeInterval = 0.07

    /// Set by ArrayController for Manual Assist participants / the
    /// full-screen camera; reverts when the session or fullscreen ends.
    var fastAnalysis = false
    /// Set true by ArrayController on the single camera currently being trimmed
    /// (fullscreen focus). Only meaningful while its mask is frozen.
    var focusedTrim = false
    /// When set, the auto-solve path logs a throttled per-frame detector
    /// diagnostic (Hough candidate count + support + the gate ladder) so the
    /// Hough-vs-gate question can be answered from the shared log.
    var diagnosticsEnabled = false
    private var lastDetectLogAt = Date.distantPast

    private var currentAnalysisInterval: TimeInterval {
        if focusedTrim && tracker.state.seeded { return Self.frozenAnalysisInterval }
        return fastAnalysis ? Self.fastAnalysisInterval : Self.analysisInterval
    }

    private var analyzing = false
    private var lastAnalysis = Date.distantPast

    var onLog: ((String) -> Void)?

    func attachSoakRecorder(_ recorder: SoakRecorder?) {
        soakRecorder = recorder
    }

    init(ip: String) {
        self.ip = ip
        stream.onLog = { [weak self] line in
            guard let self else { return }
            self.onLog?("[\(self.ip)] \(line)")
        }
        stream.onFrame = { [weak self] img in
            self?.analyzeThrottled(img)
        }
    }

    // MARK: - Lifecycle

    func connect(sourceIP: String?) {
        guard camera == nil else { return }
        let cam = CameraActor(
            ip: ip,
            sourceIP: sourceIP,
            onStatus: { [weak self] s in
                Task { @MainActor in self?.status = s }
            },
            onLog: { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.onLog?("[\(self.ip)] \(line)")
                }
            })
        camera = cam
        Task { await cam.start() }
    }

    func disconnect() {
        stream.stop()
        if let cam = camera {
            camera = nil
            Task { await cam.stop() }   // graceful close frees the slot (rule 3)
        }
        status = CameraStatus()
        tracker.reset()
        sphere = SphereState()
        match = NodeMatchInfo()
        manualMatch = ManualMatchInfo()
        seedSignature = nil
        pendingSeed = nil
        streamStale = false
        frozenSince = nil
        lastFingerprint = 0
        streamingDesired = false
    }

    func refresh() {
        guard let cam = camera else { return }
        Task { await cam.revive() }
    }

    /// True once a livestream has been intentionally started and not stopped —
    /// the signal the auto-recovery watchdog uses to tell "should be streaming but
    /// dropped" apart from "never started" or "deliberately stopped".
    private(set) var streamingDesired = false
    /// When the livestream was last (re)started. The watchdog leaves a stream
    /// alone until this is `streamStartGrace` old, so it never fights the ~0.7 s
    /// enable delay or a feed that's still delivering its first frames.
    private(set) var lastStreamStartAt: Date?

    /// Enable LIVESTREAM over the WS, then open :9090.
    func startStream() {
        guard let cam = camera else { return }
        streamingDesired = true
        lastStreamStartAt = Date()
        Task {
            _ = await cam.setLivestream(enabled: true)
            // Q100 (or the array's chosen quality), read-back verified — the
            // camera never pushes LIVESTREAM_QUALITY, so this is the only proof
            // it actually took (soak finding 2026-07-20).
            _ = await cam.setLivestreamQuality(desiredQuality)
            try? await Task.sleep(nanoseconds: 700_000_000)
            stream.start(ip: ip)
        }
    }

    func stopStream() {
        streamingDesired = false
        stream.stop()
        guard let cam = camera else { return }
        Task { _ = await cam.setLivestream(enabled: false) }
    }

    // MARK: - Capability gate (handoff §7 e-iris detection, APERTURE_NOTES)

    /// One deliberate operator action per body: capability + AE gates, valid
    /// stop list, and the APERTURE subscription the settle detector needs.
    /// Rule 11: these are unverified params — the operator presses the button
    /// knowing the session is sacrificial; nothing here runs automatically.
    func prepare() async {
        guard let cam = camera else { return }
        if let msg = await cam.benchGet(RCP2.apertureControlParam),
           let v = RCP2.extractInt(msg) {
            onLog?("[\(ip)] APERTURE_CONTROL = \(v) (\(v == 1 ? "e-iris" : "manual lens — excluded from Iris Match"))")
        } else {
            onLog?("[\(ip)] APERTURE_CONTROL: no reply — watch TC for a wedge (rule 11)")
        }
        if let msg = await cam.benchGet(RCP2.aeModeParam), let v = RCP2.extractInt(msg), v != 0 {
            onLog?("[\(ip)] WARNING: AE_MODE = \(v) — AE may own the iris and fight the loop")
        }
        let list = await cam.getApertureList()
        if !list.isEmpty {
            onLog?("[\(ip)] stop list (\(list.count)): \(list.map { RCP2.stopLabel($0) }.joined(separator: " "))")
        }
        await cam.setApertureSubscription(true)   // pushed cur/target = settle detector

        // Transform preflight extension: read the monitor output actually
        // mirrored into :9090. Deliberate Prepare action only (rule 11).
        let transform = await cam.readActiveMonitorTransform()
        let value = transform.presetValue.map(String.init) ?? "no reply"
        onLog?("[\(ip)] viewing transform = \(transform.state.rawValue) (\(transform.parameterID.isEmpty ? "active output unknown" : transform.parameterID) \(value))")
    }

    /// Participates in Iris Match / the match loop only when the body says the
    /// mounted lens is electronically controllable (APERTURE_CONTROL == 1).
    var eIris: Bool { status.apertureControl == 1 }
    var connected: Bool { status.link == .connected }

    // MARK: - Analysis

    private func analyzeThrottled(_ img: CGImage) {
        guard !analyzing, Date().timeIntervalSince(lastAnalysis) >= currentAnalysisInterval else { return }
        analyzing = true
        lastAnalysis = Date()
        let handle = FrameHandle(image: img)
        let trackerSnapshot = tracker
        let sig = seedSignature
        let analysisStarted = DispatchTime.now().uptimeNanoseconds

        Task.detached(priority: .utility) { [weak self] in
            var detection: SphereDetection?
            var grid: WaveformGrid?
            var fingerprint: UInt64 = 0
            if let buf = PixelBuffer.from(handle.image) {
                let prior = trackerSnapshot.prior(forBufferWidth: buf.width, height: buf.height)
                if trackerSnapshot.state.seeded, let prior {
                    // Operator-approved lock is FROZEN: never re-detect or move
                    // it. Measure hero IRE at the fixed ROI so the reading stays
                    // live, and let the tracker hold the lock in place.
                    detection = SphereDetection(status: .coasting, roi: prior,
                                                heroIRE: SphereDetector.measure(in: buf, roi: prior),
                                                gates: [], failureReason: "seeded",
                                                bufferWidth: buf.width, bufferHeight: buf.height)
                } else {
                    var det = SphereDetector.detect(in: buf, prior: prior, signature: sig)
                    // Coasting: detection failed but we hold a lock — the sphere
                    // is static, so measure at the locked ROI and let the tracker
                    // count the miss.
                    if det.status == .failed, let prior,
                       trackerSnapshot.state.phase == .locked || trackerSnapshot.state.phase == .coasting {
                        det = SphereDetection(status: .coasting, roi: prior,
                                              heroIRE: SphereDetector.measure(in: buf, roi: prior),
                                              gates: det.gates, failureReason: det.failureReason,
                                              bufferWidth: buf.width, bufferHeight: buf.height)
                    }
                    detection = det
                }
                grid = WaveformGrid.compute(from: buf)
                fingerprint = CameraNode.frameFingerprint(buf)
            }
            let det = detection
            let g = grid
            let fp = fingerprint
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - analysisStarted) / 1_000_000
            // `self` here is the weak-captured VAR from the detached closure;
            // rebinding to an immutable local before the @Sendable MainActor
            // closure captures it silences the Swift-6 "captured var" warning
            // without changing semantics.
            let node = self
            await MainActor.run {
                node?.applyAnalysis(detection: det, grid: g, analysisMS: elapsedMS, fingerprint: fp)
            }
        }
    }

    /// Cheap frozen-frame fingerprint: FNV-1a over a strided luma sample.
    /// Two consecutive identical values while streaming ⇒ the feed has stalled.
    nonisolated private static func frameFingerprint(_ buf: PixelBuffer) -> UInt64 {
        var acc: UInt64 = 1469598103934665603   // FNV offset basis
        let step = max(1, buf.luma.count / 512)
        var i = 0
        while i < buf.luma.count {
            acc = (acc ^ UInt64(buf.luma[i] * 255)) &* 1099511628211
            i += step
        }
        return acc
    }

    private func applyAnalysis(detection: SphereDetection?, grid: WaveformGrid?,
                               analysisMS: Double, fingerprint: UInt64) {
        analyzing = false
        updateStreamHealth(fingerprint: fingerprint)
        if let detection {
            tracker.update(with: detection)
            sphere = tracker.state
        }
        if let grid { waveform = grid }
        // Detector diagnostics: only the auto-solve path (unseeded), throttled,
        // and never for a coasting frame (measured at a prior lock, no gates run).
        if diagnosticsEnabled, !tracker.state.seeded,
           let d = detection, d.status != .coasting {
            let now = Date()
            if now.timeIntervalSince(lastDetectLogAt) >= 1.5 {
                lastDetectLogAt = now
                logDetectDiagnostic(d)
            }
        }
        soakRecorder?.record(cameraIP: ip,
                             streamFPS: stream.stats.fps,
                             analysisMS: analysisMS,
                             detection: detection,
                             state: sphere)
    }

    private func logDetectDiagnostic(_ d: SphereDetection) {
        let ladder = d.gates.map { g in
            "\(g.gate)=\(String(format: "%.4g", g.value))\(g.passed ? "✓" : "✗")"
        }.joined(separator: " ")
        let head: String
        switch d.status {
        case .success, .successPass2:
            let r = d.roi.map { String(format: "%.0fpx", $0.r) } ?? "?"
            head = "OK(\(d.status.rawValue)) cands=\(d.candidateCount) support=\(String(format: "%.2f", d.topSupport)) r=\(r)"
        default:
            head = "MISS(\(d.failureReason)) cands=\(d.candidateCount) topSupport=\(String(format: "%.2f", d.topSupport))"
        }
        onLog?("[\(ip)] detect: \(head)\(ladder.isEmpty ? "" : " · " + ladder)")
    }

    /// Operator escape hatch: forget the current track (and any seed) and
    /// re-search from scratch.
    func redetect() {
        seedSignature = nil
        pendingSeed = nil
        tracker.reset(detail: "operator re-detect")
        sphere = tracker.state
    }

    // MARK: - Operator seeding / signature / quality

    /// Operator clicked the sphere center (normalized). Start a PENDING seed:
    /// a candidate ROI the operator sizes and approves. The initial radius is a
    /// limb fit CLAMPED to the calibrated band (the raw fit balloons/collapses,
    /// bench 2026-07-20) — a starting point, not the final size. Center stays
    /// exactly where the operator clicked; the fit only proposes a radius.
    func beginSeed(normX: Double, normY: Double) {
        guard let img = stream.frame, let buf = PixelBuffer.from(img) else { return }
        let w = Double(buf.width), h = Double(buf.height)
        let normW = min(w, h * 16.0 / 9.0)
        let guessR = tracker.state.hasROI ? tracker.state.r * w : normW * 0.09
        let fit = SphereDetector.refineToLimb(SphereROI(cx: normX * w, cy: normY * h, r: guessR), in: buf)
        let rClamped = min(max(fit.r, normW * 0.03), normW * 0.30)
        pendingSeed = PendingSeed(cx: normX, cy: normY, r: rClamped / w)
        onLog?("[\(ip)] sphere: seeding — size the mask, then Approve")
    }

    /// Resize the pending mask (normalized-by-width radius).
    func setSeedRadius(_ rNorm: Double) {
        guard var p = pendingSeed else { return }
        p.r = min(max(rNorm, 0.02), 0.32)
        pendingSeed = p
    }

    /// Re-place the pending mask center (normalized), keeping the current size.
    func moveSeedCenter(normX: Double, normY: Double) {
        guard var p = pendingSeed else { return }
        p.cx = min(max(normX, 0), 1)
        p.cy = min(max(normY, 0), 1)
        pendingSeed = p
    }

    func cancelSeed() {
        if pendingSeed != nil { onLog?("[\(ip)] sphere: seed cancelled") }
        pendingSeed = nil
    }

    /// Approve the pending mask: measure hero IRE at it, lock the tracker
    /// (bypasses the gate pipeline — a human sized and confirmed it), and
    /// return the sphere signature for array broadcast. nil if nothing pending.
    @discardableResult
    func approveSeed() -> SphereSignature? {
        guard let p = pendingSeed, let img = stream.frame, let buf = PixelBuffer.from(img) else {
            pendingSeed = nil
            return nil
        }
        let w = Double(buf.width), h = Double(buf.height)
        let roi = SphereROI(cx: p.cx * w, cy: p.cy * h, r: p.r * w)
        let hero = SphereDetector.measure(in: buf, roi: roi)
        tracker.manualLock(cx: p.cx, cy: p.cy, r: p.r, heroIRE: hero)
        sphere = tracker.state
        let sig = SphereDetector.profile(at: roi, in: buf)
        seedSignature = sig   // the hero keeps its own signature too
        onLog?("[\(ip)] sphere: seed approved r=\(Int(roi.r))px heroIRE=\(hero.map { String(format: "%.1f", $0) } ?? "n/a")")
        pendingSeed = nil
        return sig
    }

    /// Accept a hero-seed signature to bias this camera's detector toward the
    /// matching sphere (does not force a lock — the detector still finds its own
    /// position in its own frame).
    func applySignature(_ sig: SphereSignature) {
        seedSignature = sig
    }

    /// One-click accept of the CURRENT auto-detected mask as the seed — no
    /// fullscreen, no click-to-place. Freezes the tracker at its present ROI and
    /// returns the broadcast signature, exactly like approveSeed but sourced from
    /// the live track instead of an operator-placed pending seed. nil if there's
    /// no usable mask (nothing detected, or no frame).
    @discardableResult
    func acceptCurrentMask() -> SphereSignature? {
        guard tracker.state.hasROI, let img = stream.frame, let buf = PixelBuffer.from(img) else {
            return nil
        }
        let cx = tracker.state.cx, cy = tracker.state.cy, r = tracker.state.r
        let w = Double(buf.width), h = Double(buf.height)
        let roi = SphereROI(cx: cx * w, cy: cy * h, r: r * w)
        let hero = SphereDetector.measure(in: buf, roi: roi)
        tracker.manualLock(cx: cx, cy: cy, r: r, heroIRE: hero)
        sphere = tracker.state
        let sig = SphereDetector.profile(at: roi, in: buf)
        seedSignature = sig
        pendingSeed = nil
        onLog?("[\(ip)] sphere: accepted auto mask r=\(Int(roi.r))px heroIRE=\(hero.map { String(format: "%.1f", $0) } ?? "n/a")")
        return sig
    }

    /// Freeze the current lock so a deliberate Log3G10 swap can't drop the mask.
    /// Returns true if newly frozen (reversible via unfreezeTransformLock()).
    @discardableResult
    func freezeTransformLock() -> Bool {
        let froze = tracker.freezeAtCurrentLock()
        if froze { sphere = tracker.state }
        return froze
    }

    /// Reverse freezeTransformLock() once the transform experiment ends.
    func unfreezeTransformLock() {
        tracker.unfreeze()
        sphere = tracker.state
    }

    /// Apply a livestream quality now (and remember it for the next stream
    /// start). Read-back verified inside CameraActor.
    func applyQuality(_ q: Int) {
        desiredQuality = q
        guard let cam = camera else { return }
        Task { _ = await cam.setLivestreamQuality(q) }
    }

    private func updateStreamHealth(fingerprint: UInt64) {
        guard stream.isStreaming else {
            frozenSince = nil; lastFingerprint = 0
            if streamStale { streamStale = false }
            return
        }
        if fingerprint != 0 && fingerprint == lastFingerprint {
            if frozenSince == nil { frozenSince = Date() }
            if let since = frozenSince,
               Date().timeIntervalSince(since) >= Self.freezeGrace, !streamStale {
                streamStale = true
                onLog?("[\(ip)] stream: FROZEN — frames unchanged for ≥\(Int(Self.freezeGrace))s (check the feed / mirror source)")
            }
        } else {
            if streamStale { onLog?("[\(ip)] stream: recovered") }
            frozenSince = nil
            streamStale = false
        }
        lastFingerprint = fingerprint
    }
}

/// A sphere mask the operator is placing/sizing before approving it.
/// All fields normalized: cx = x/width, cy = y/height, r = radius/width.
struct PendingSeed: Equatable {
    var cx: Double
    var cy: Double
    var r: Double
}

// MARK: - Match bookkeeping

struct NodeMatchInfo: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle
        case adjusting
        case matched
        case capped        // hit the DoF nudge budget — residual spills to exposureAdjust
        case oscillating   // granularity floor reached; tolerance tighter than 1 list step
        case excluded      // no e-iris / no sphere / disconnected
    }
    var phase: Phase = .idle
    var deltaIRE: Double? = nil       // measured − reference (display-referred)
    var deltaStops: Double? = nil     // Log3G10 correction: log2(linear ref / measured)
    var nudgesUsed: Int = 0
    /// +1 list step must darken (higher stop). Auto-learned by the loop and
    /// flipped per camera if the first correction moves the wrong way.
    /// # UNVERIFIED: stop-list ordering is assumed ascending until benched.
    var directionFlipped: Bool = false
    var note: String = ""

    /// Residual expressed in (display-referred!) stops for the exposureAdjust
    /// spill (handoff §7 hybrid). log2 of the IRE ratio — an estimate only;
    /// R3DMatch owns the scene-linear truth.
    var residualStops: Double? = nil
}

/// Human-in-the-loop iris guidance for a non-electronic lens. Positive
/// correction means the camera needs more exposure (OPEN); negative means it
/// needs less (CLOSE). The fixed target belongs to the array session.
struct ManualMatchInfo: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle = "IDLE"
        case acquiring = "ACQUIRE"
        case open = "OPEN"
        case close = "CLOSE"
        case hold = "HOLD"
        case matched = "MATCHED"
        case unavailable = "NO SIGNAL"
    }

    var phase: Phase = .idle
    var baselineIRE: Double? = nil
    var currentIRE: Double? = nil
    var targetIRE: Double? = nil
    var correctionStops: Double? = nil
    var deltaIRE: Double? = nil
    /// 0...1 progress through the stability hold once inside tolerance.
    var stability: Double = 0
    /// The session's match tolerance in stops — sizes the HUD's target band
    /// so the gauge shows the REAL capture zone, not a cosmetic one.
    var toleranceStops: Double = 0.10
    var detail: String = ""
}
