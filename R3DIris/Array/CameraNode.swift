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
    /// Match-loop bookkeeping, published for the per-camera delta readout.
    @Published var match = NodeMatchInfo()

    let stream = MJPEGStreamReader()
    private(set) var camera: CameraActor?
    private var tracker = SphereTracker()
    private weak var soakRecorder: SoakRecorder?

    /// Analysis cadence — ~3 Hz keeps 12 nodes cheap; the loop's debounce
    /// dominates responsiveness anyway (handoff §8: don't chase noise).
    static let analysisInterval: TimeInterval = 0.33

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
    }

    func refresh() {
        guard let cam = camera else { return }
        Task { await cam.revive() }
    }

    /// Enable LIVESTREAM over the WS, then open :9090.
    func startStream() {
        guard let cam = camera else { return }
        Task {
            _ = await cam.setLivestream(enabled: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            stream.start(ip: ip)
        }
    }

    func stopStream() {
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
        guard !analyzing, Date().timeIntervalSince(lastAnalysis) >= Self.analysisInterval else { return }
        analyzing = true
        lastAnalysis = Date()
        let handle = FrameHandle(image: img)
        let trackerSnapshot = tracker
        let analysisStarted = DispatchTime.now().uptimeNanoseconds

        Task.detached(priority: .utility) { [weak self] in
            var detection: SphereDetection?
            var grid: WaveformGrid?
            if let buf = PixelBuffer.from(handle.image) {
                let prior = trackerSnapshot.prior(forBufferWidth: buf.width, height: buf.height)
                var det = SphereDetector.detect(in: buf, prior: prior)
                // Coasting: detection failed but we hold a lock — the sphere is
                // static, so measure at the locked ROI and let the tracker
                // count the miss.
                if det.status == .failed, let prior,
                   trackerSnapshot.state.phase == .locked || trackerSnapshot.state.phase == .coasting {
                    det = SphereDetection(status: .coasting, roi: prior,
                                          heroIRE: SphereDetector.measure(in: buf, roi: prior),
                                          gates: det.gates, failureReason: det.failureReason,
                                          bufferWidth: buf.width, bufferHeight: buf.height)
                }
                detection = det
                grid = WaveformGrid.compute(from: buf)
            }
            let det = detection
            let g = grid
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - analysisStarted) / 1_000_000
            await MainActor.run {
                self?.applyAnalysis(detection: det, grid: g, analysisMS: elapsedMS)
            }
        }
    }

    private func applyAnalysis(detection: SphereDetection?, grid: WaveformGrid?, analysisMS: Double) {
        analyzing = false
        if let detection {
            tracker.update(with: detection)
            sphere = tracker.state
        }
        if let grid { waveform = grid }
        soakRecorder?.record(cameraIP: ip,
                             streamFPS: stream.stats.fps,
                             analysisMS: analysisMS,
                             detection: detection,
                             state: sphere)
    }

    /// Operator escape hatch: forget the current track and re-search.
    func redetect() {
        tracker.reset(detail: "operator re-detect")
        sphere = tracker.state
    }
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
