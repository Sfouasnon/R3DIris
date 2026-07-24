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
    enum StreamRole: String, Sendable {
        /// Normal multiview / sphere-solving behavior.
        case normal
        /// Local HTTP reader intentionally closed; RCP and camera settings stay up.
        case parked
        /// The next Manual Assist camera, kept ready for a quick handoff.
        case warm
        /// The fullscreen camera currently being adjusted by the operator.
        case focused
    }

    nonisolated let id = UUID()
    let ip: String

    @Published private(set) var status = CameraStatus()
    @Published private(set) var sphere = SphereState()
    @Published private(set) var waveform: WaveformGrid? = nil
    /// Legacy UI signal retained for compatibility. Transport recovery is based
    /// exclusively on MJPEG arrival timestamps; identical image content is valid
    /// for a locked, stationary sphere and never marks the stream stale.
    @Published private(set) var streamStale = false
    /// Local Manual Assist stream scheduling. Parked closes only this Mac's HTTP
    /// reader; it never disables the camera encoder, changes quality, or touches
    /// the RCP session.
    @Published private(set) var streamRole: StreamRole = .normal
    /// True from a local HTTP wake/reopen until three fresh native measurements
    /// arrive. Fullscreen guidance remains paused for that entire interval.
    @Published private(set) var streamRecovering = false
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

    /// When set, the auto-solve path logs a throttled per-frame detector
    /// diagnostic (Hough candidate count + support + the gate ladder) so the
    /// Hough-vs-gate question can be answered from the shared log.
    var diagnosticsEnabled = false
    private var lastDetectLogAt = Date.distantPast
    private var lastNativeProbeFailureLogAt = Date.distantPast

    private var currentAnalysisInterval: TimeInterval {
        switch streamRole {
        case .focused:
            return tracker.state.seeded ? Self.frozenAnalysisInterval : Self.fastAnalysisInterval
        case .warm:
            return Self.fastAnalysisInterval
        case .normal:
            return Self.analysisInterval
        case .parked:
            return .infinity
        }
    }

    private var analyzing = false
    private var lastAnalysis = Date.distantPast
    private var streamOperationTask: Task<Void, Never>?
    private var streamIntentGeneration: UInt64 = 0
    /// Set only after an actual LIVESTREAM_QUALITY read-back. Local HTTP
    /// recovery is never allowed to bypass that initial measurement invariant.
    private var streamSettingsVerified = false
    private var recoveryStartedAt: Date?
    private var recoveryFreshMeasurements = 0
    private var recoveryStreamGeneration: UInt64?
    /// Planned scheduler wakes are intentionally quiet. If a wake turns into a
    /// real retry, logging is promoted for that recovery generation.
    private var recoveryLogsEnabled = false
    private var lastLocalReaderOpenAt = Date.distantPast

    var onLog: ((String) -> Void)?
    var onStatusChange: ((CameraNode) -> Void)?

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
            self?.streamFrameDecoded(img)
        }
    }

    // MARK: - Lifecycle

    func connect(sourceIP: String?) {
        guard camera == nil else { return }
        let cam = CameraActor(
            ip: ip,
            sourceIP: sourceIP,
            onStatus: { [weak self] s in
                Task { @MainActor in
                    guard let self else { return }
                    self.status = s
                    self.onStatusChange?(self)
                }
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
        streamIntentGeneration &+= 1
        streamOperationTask?.cancel()
        streamOperationTask = nil
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
        streamingDesired = false
        streamSettingsVerified = false
        streamRole = .normal
        stream.minimumDecodeInterval = 0
        streamRecovering = false
        recoveryStartedAt = nil
        recoveryFreshMeasurements = 0
        recoveryStreamGeneration = nil
        recoveryLogsEnabled = false
        onStatusChange?(self)
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

        // A camera whose encoder was already enabled has only lost or parked its
        // local HTTP reader. Reopening it must not churn LIVESTREAM_ENABLE or
        // LIVESTREAM_QUALITY over RCP.
        if streamingDesired, streamSettingsVerified {
            let wasParked = streamRole == .parked
            setStreamRole(.normal)
            if !wasParked, !stream.isStreaming {
                reopenLocalStream(reason: "operator wake", attempt: 1)
            }
            return
        }

        streamingDesired = true
        streamSettingsVerified = false
        setDecodePolicy(for: .normal)
        streamIntentGeneration &+= 1
        let intent = streamIntentGeneration
        let requestedQuality = desiredQuality
        streamOperationTask?.cancel()
        lastStreamStartAt = Date()
        resetContentHealth()
        streamOperationTask = Task { [weak self] in
            guard let self, !Task.isCancelled,
                  self.streamingDesired, self.streamIntentGeneration == intent else { return }
            defer {
                if self.streamIntentGeneration == intent {
                    self.streamOperationTask = nil
                }
            }
            let enabled = await cam.setLivestream(enabled: true)
            guard !Task.isCancelled, self.streamingDesired,
                  self.streamIntentGeneration == intent else { return }
            guard enabled else {
                self.onLog?("[\(self.ip)] stream: NOT OPENED — LIVESTREAM_ENABLE command failed")
                return
            }
            // Q100 (or the array's chosen quality), read-back verified — the
            // camera never pushes LIVESTREAM_QUALITY, so this is the only proof
            // it actually took (soak finding 2026-07-20).
            let quality = await cam.setLivestreamQuality(requestedQuality)
            guard !Task.isCancelled, self.streamingDesired,
                  self.streamIntentGeneration == intent else { return }
            guard let actual = quality.actual else {
                self.onLog?("[\(self.ip)] stream: NOT OPENED — LIVESTREAM_QUALITY has no actual read-back")
                return
            }
            self.streamSettingsVerified = true
            if actual != requestedQuality {
                self.onLog?("[\(self.ip)] stream: requested \(RCP2.livestreamQualityLabels[requestedQuality] ?? "\(requestedQuality)"), camera actual \(RCP2.livestreamQualityLabels[actual] ?? "\(actual)"); array measurement remains blocked until participant read-backs agree")
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, self.streamingDesired,
                  self.streamIntentGeneration == intent, self.streamRole != .parked else { return }
            self.stream.start(ip: self.ip)
        }
    }

    func stopStream() {
        streamIntentGeneration &+= 1
        streamOperationTask?.cancel()
        streamOperationTask = nil
        streamingDesired = false
        streamSettingsVerified = false
        streamRole = .normal
        stream.minimumDecodeInterval = 0
        streamRecovering = false
        recoveryStartedAt = nil
        recoveryFreshMeasurements = 0
        recoveryStreamGeneration = nil
        recoveryLogsEnabled = false
        resetContentHealth()
        stream.stop()
        guard let cam = camera else { return }
        let intent = streamIntentGeneration
        streamOperationTask = Task { [weak self] in
            guard let self, !Task.isCancelled,
                  !self.streamingDesired, self.streamIntentGeneration == intent else { return }
            defer {
                if self.streamIntentGeneration == intent {
                    self.streamOperationTask = nil
                }
            }
            _ = await cam.setLivestream(enabled: false)
        }
    }

    /// Manual Assist scheduler entry point. Moving to `.parked` closes only the
    /// local HTTP reader; the RCP session, camera encoder enable, actual quality,
    /// frozen ROI, and last decoded frame remain untouched. Leaving `.parked`
    /// performs an HTTP-only wake and therefore cannot churn camera settings.
    func setStreamRole(_ role: StreamRole) {
        guard streamRole != role else { return }
        let previous = streamRole
        setDecodePolicy(for: role)

        if role == .parked {
            streamRecovering = false
            recoveryStartedAt = nil
            recoveryFreshMeasurements = 0
            recoveryStreamGeneration = nil
            recoveryLogsEnabled = false
            resetContentHealth()
            // Always advance the reader generation so a decode already in
            // flight cannot publish after this camera has been parked.
            stream.stop(log: false)
            return
        }

        guard previous == .parked, streamingDesired else { return }
        reopenLocalStream(
            reason: "\(role.rawValue) wake",
            attempt: 1,
            logTransitions: false
        )
    }

    /// HTTP-only recovery. This never sends LIVESTREAM_ENABLE and never reads or
    /// writes LIVESTREAM_QUALITY. ArrayController owns retry timing so attempts
    /// cannot fan out on every 20 Hz guidance tick.
    func reopenLocalStream(
        reason: String,
        attempt: Int,
        logTransitions: Bool = true
    ) {
        guard streamingDesired, streamSettingsVerified,
              streamRole != .parked else { return }
        // Let an initial enable/quality transaction finish rather than opening
        // an unverified feed underneath it. Scheduled retries will return here
        // after that operation completes.
        guard streamOperationTask == nil else { return }
        // A role wake and the controller watchdog can notice the same missing
        // feed on adjacent ticks. Bound restarts locally as a final defense
        // against reopening the socket twice before it can deliver a first JPEG.
        if streamRecovering {
            let minimumInterval: TimeInterval
            switch streamRole {
            case .focused: minimumInterval = 0.75
            case .warm: minimumInterval = 2
            case .normal: minimumInterval = 4
            case .parked: return
            }
            guard Date().timeIntervalSince(lastLocalReaderOpenAt) >= minimumInterval else { return }
        }
        let firstAttempt = !streamRecovering
        if firstAttempt {
            streamRecovering = true
            recoveryStartedAt = Date()
            recoveryFreshMeasurements = 0
            recoveryLogsEnabled = logTransitions
            if logTransitions {
                onLog?("[\(ip)] stream: recovering — \(reason)")
            }
        } else if logTransitions {
            if recoveryLogsEnabled {
                if attempt > 1 {
                    onLog?("[\(ip)] stream: recovery retry \(attempt)")
                }
            } else {
                recoveryLogsEnabled = true
                onLog?("[\(ip)] stream: planned wake stalled — recovery retry \(attempt)")
            }
        }
        lastStreamStartAt = Date()
        resetContentHealth()
        stream.start(ip: ip, logHandshake: false)
        lastLocalReaderOpenAt = Date()
        // A retry is a new HTTP generation: prior successes cannot be carried
        // across it, and an analysis finishing from the replaced reader cannot
        // certify recovery.
        recoveryFreshMeasurements = 0
        recoveryStreamGeneration = stream.generation
    }

    private func setDecodePolicy(for role: StreamRole) {
        streamRole = role
        switch role {
        case .focused:
            stream.minimumDecodeInterval = 0
        case .warm:
            stream.minimumDecodeInterval = 0.12
        case .normal:
            stream.minimumDecodeInterval = 0
        case .parked:
            stream.minimumDecodeInterval = 1
        }
    }

    private func resetContentHealth() {
        streamStale = false
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

    private func streamFrameDecoded(_ img: CGImage) {
        analyzeThrottled(img, streamGeneration: stream.generation)
    }

    private func analyzeThrottled(_ img: CGImage, streamGeneration: UInt64) {
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
            if let buf = PixelBuffer.from(handle.image) {
                let prior = trackerSnapshot.prior(forBufferWidth: buf.width, height: buf.height)
                if trackerSnapshot.state.seeded, let prior {
                    // Operator-approved lock is FROZEN: never re-detect or move
                    // it. The common native-probe step below measures hero IRE
                    // at the fixed ROI while the tracker holds the lock.
                    detection = SphereDetection(status: .coasting, roi: prior,
                                                heroIRE: nil,
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
                                              heroIRE: nil,
                                              gates: det.gates, failureReason: det.failureReason,
                                              bufferWidth: buf.width, bufferHeight: buf.height)
                    }
                    detection = det
                }
                // Detect, gate, and maintain geometry in the 480 px working
                // buffer, then reproject only the approved center probe onto
                // the decoded native frame (normally 1920×1080). Overwrite the
                // detector's low-resolution estimate even when the native
                // probe fails; a nil reading is safer than silently mixing
                // measurement resolutions.
                if var det = detection, let roi = det.roi {
                    det.heroIRE = NativeIREProbe.measureHero(
                        in: handle.image,
                        detectionROI: roi,
                        bufferWidth: det.bufferWidth,
                        bufferHeight: det.bufferHeight
                    )?.ire
                    detection = det
                }
                grid = WaveformGrid.compute(from: buf)
            }
            let det = detection
            let g = grid
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - analysisStarted) / 1_000_000
            // `self` here is the weak-captured VAR from the detached closure;
            // rebinding to an immutable local before the @Sendable MainActor
            // closure captures it silences the Swift-6 "captured var" warning
            // without changing semantics.
            let node = self
            await MainActor.run {
                node?.applyAnalysis(
                    detection: det,
                    grid: g,
                    analysisMS: elapsedMS,
                    streamGeneration: streamGeneration
                )
            }
        }
    }

    private func applyAnalysis(detection: SphereDetection?, grid: WaveformGrid?,
                               analysisMS: Double, streamGeneration: UInt64) {
        analyzing = false
        // stop/start invalidates any detached analysis still in flight. Never
        // publish its tracker state or count it toward recovery.
        guard streamGeneration == stream.generation else { return }
        if let detection {
            tracker.update(with: detection)
            sphere = tracker.state
            if streamRecovering, recoveryStreamGeneration == streamGeneration {
                if detection.heroIRE != nil {
                    recoveryFreshMeasurements += 1
                    if recoveryFreshMeasurements >= 3 {
                        let elapsed = recoveryStartedAt.map {
                            Date().timeIntervalSince($0)
                        } ?? 0
                        streamRecovering = false
                        recoveryStartedAt = nil
                        recoveryFreshMeasurements = 0
                        recoveryStreamGeneration = nil
                        if recoveryLogsEnabled {
                            onLog?("[\(ip)] stream: recovered in \(String(format: "%.1f", elapsed))s — 3 fresh native measurements")
                        }
                        recoveryLogsEnabled = false
                    }
                } else {
                    recoveryFreshMeasurements = 0
                }
            }
            if detection.roi != nil, detection.heroIRE == nil {
                let now = Date()
                if now.timeIntervalSince(lastNativeProbeFailureLogAt) >= 3.0 {
                    lastNativeProbeFailureLogAt = now
                    let dimensions = "\(stream.stats.width)×\(stream.stats.height)"
                    let requirement = stream.stats.width == NativeIREProbe.requiredSourceWidth
                        && stream.stats.height == NativeIREProbe.requiredSourceHeight
                        ? ""
                        : "; matching requires 1920×1080"
                    onLog?("[\(ip)] measure: native ROI probe unavailable (\(dimensions)\(requirement)) — no 480 px fallback used")
                }
            }
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
        let hero = NativeIREProbe.measureHero(
            in: img,
            normalizedCenterX: p.cx,
            normalizedCenterY: p.cy,
            normalizedRadiusByWidth: p.r
        )?.ire
        tracker.manualLock(cx: p.cx, cy: p.cy, r: p.r, heroIRE: hero)
        sphere = tracker.state
        var sig = SphereDetector.profile(at: roi, in: buf)
        sig.heroIRE = hero
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
        let hero = NativeIREProbe.measureHero(
            in: img,
            normalizedCenterX: cx,
            normalizedCenterY: cy,
            normalizedRadiusByWidth: r
        )?.ire
        tracker.manualLock(cx: cx, cy: cy, r: r, heroIRE: hero)
        sphere = tracker.state
        var sig = SphereDetector.profile(at: roi, in: buf)
        sig.heroIRE = hero
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
        case recovering = "HOLD - RECOVERING"
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
