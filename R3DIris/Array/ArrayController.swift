//  ArrayController.swift — R3DIris / Array (Phase 2)
//  The Iris Match: multi-camera session management, bulk T-stop push, and the
//  closed exposure-match loop (handoff §8) driven by the gray-sphere hero IRE
//  measured on each body's livestream.
//
//  Loop design (handoff §8 + APERTURE_NOTES):
//    measure sphere level per camera → compute delta vs reference →
//    nudge iris ONE list step (rcp_set_list_relative) → wait cur == target
//    (the pushed settle detector) → debounce past stream latency →
//    re-measure → repeat until |delta| ≤ tolerance for every participant.
//
//  Why single-step nudges instead of computed absolute stops: the stream is
//  display-referred through an unknown monitor transform (LIVESTREAM_NOTES
//  caveat 1), so IRE deltas don't map linearly to stops. A bounded iterative
//  nudge converges regardless of the transfer function and can never
//  overshoot by more than one list step. Granularity floor: 1/4 stop
//  (APERTURE_LIST_MODE) — residual below that spills to exposureAdjust.
//
//  Safety (handoff §8): DoF nudge budget caps how far irises are dialed
//  apart; oscillation detection stops a camera that straddles the target;
//  the operator can abort at any time; sets go through the camera's own
//  valid-stop list so range limits are respected by construction.

import Foundation
import SwiftUI
import AppKit

@MainActor
final class ArrayController: ObservableObject {

    // MARK: Array membership

    @Published var newIP: String = ""
    @Published var sourceIP: String = ""       // field notes rule 16 (link-local NICs)
    @Published private(set) var nodes: [CameraNode] = []
    @Published var selectedNodeID: UUID? = nil
    /// Double-clicked tile shown full-screen with the large trim overlay.
    @Published var fullScreenNodeID: UUID? = nil

    var fullScreenNode: CameraNode? { nodes.first { $0.id == fullScreenNodeID } }

    /// When on, unseeded cameras log a throttled detector diagnostic (Hough
    /// candidate count + support + gate ladder). Pushed to every node so it
    /// applies to auto-solving spheres you leave un-seeded.
    @Published var logSphereDiagnostics = false {
        didSet { for n in nodes { n.diagnosticsEnabled = logSphereDiagnostics } }
    }

    // MARK: - Latency options (shown in the match panel for both workflows)
    /// Decode only the freshest buffered livestream frame, dropping stale ones —
    /// keeps display latency from creeping and offloads the main thread.
    @Published var dropStaleFrames = true {
        didSet { for n in nodes { n.stream.dropToLatestFrame = dropStaleFrames } }
    }
    /// Temporarily lower the fullscreen-focused camera's stream quality while
    /// trimming it — smaller frames, less encode/transmit/decode lag on the one
    /// camera a hand is on; other cameras keep full quality. Restored on unfocus.
    @Published var lowerFocusStreamQuality = false
    /// Q25 — enough of a size cut to matter; the focused camera is frozen and
    /// measured at a fixed ROI, so the flatter JPEG doesn't affect its reading.
    private static let focusLowQuality = 1
    private var focusQualityNodeID: UUID?

    // MARK: Discovery (V3's method, ported: TCP subnet sweep on :9998 primary,
    // UDP CAMINFO broadcast fallback — both spend ZERO camera session slots.
    // Manual IP entry remains as the fallback path.)

    @Published var subnet: String = ""         // CIDR / bare / shorthand (Subnet.hosts)
    @Published private(set) var discovering = false
    @Published private(set) var discovered: [DiscoveredCamera] = []

    // MARK: Livestream quality (array-wide)
    // Q100 default: low-Q JPEG flattens the sphere's shading gradient, which
    // collapses ire_spread to ~0 and blocks lock (soak finding 2026-07-20).
    // Every push is read-back verified per body (CameraActor). Drop it only if
    // viewing many streams strains the GigE segment — LIVESTREAM_NOTES ch.7.
    @Published var arrayQuality: Int = 4   // 1=Q25 2=Q50 3=Q75 4=Q100

    var subnetHostCount: Int { Subnet.hosts(from: subnet).count }

    // MARK: Iris Match (bulk T-stop push)

    @Published var linkStopText: String = "5.6"

    enum MatchWorkflow: String, CaseIterable, Identifiable {
        case electronic = "Electronic"
        case manual = "Manual Assist"
        var id: String { rawValue }
    }
    @Published var matchWorkflow: MatchWorkflow = .electronic

    // MARK: Match loop config

    enum ReferenceMode: String, CaseIterable, Identifiable {
        case median = "Median camera"
        case hero = "Selected camera"
        case gray18 = "18% gray anchor"
        case custom = "Custom IRE"
        var id: String { rawValue }
    }
    @Published var referenceMode: ReferenceMode = .median
    @Published var loopTargetText: String = String(format: "%.1f", Log3G10.grayAnchorIRE)

    /// 18% gray's IRE through the IPP2 display path (medium contrast / medium
    /// detail) — operator value 42.3 (Stephen 2026-07-20; earlier "41–43").
    /// # PROVISIONAL: display-path-dependent, refine on the bench against a
    /// metered gray sphere. The Log3G10 anchor (33.3) is exact; this is not.
    static let ipp2GrayAnchorIRE = 42.3

    var loopCustomTargetIRE: Double? {
        guard let value = Double(loopTargetText.trimmingCharacters(in: .whitespaces)),
              value > 0, value < 100 else { return nil }
        return value
    }
    @Published var toleranceIRE: Double = 2.0      // convergence tolerance (±IRE)
    @Published var toleranceStops: Double = 0.05   // Log3G10 scene-linear convergence tolerance
    @Published var nudgeBudget: Int = 8            // DoF cap in list steps (8 × ¼-stop = 2 stops)
    @Published var debounceSeconds: Double = 1.5   // stream-latency debounce; bench-measure and tune

    enum LoopState: Equatable {
        case idle
        case running(round: Int)
        case finished(String)
    }
    @Published private(set) var loopState: LoopState = .idle
    @Published private(set) var referenceIRE: Double? = nil
    @Published private(set) var loopUsesLog3G10 = false

    // MARK: Manual Assist config + session

    enum ManualTargetMode: String, CaseIterable, Identifiable {
        case median = "Captured median"
        case gray18 = "18% gray anchor"
        case custom = "Custom IRE"
        var id: String { rawValue }
    }

    /// Monitoring transform the match runs in. Log3G10 (preferred) swaps the
    /// mirrored outputs to Log3G10 and anchors 18% gray at 33.3 IRE. Display
    /// leaves the current transform untouched and anchors 18% gray at the IPP2
    /// value (42.3) — the only workable path when the mirrored output can't
    /// carry Log3G10 (e.g. the built-in LCD, which rejects the preset).
    enum ManualTransform: String, CaseIterable, Identifiable {
        case log3g10 = "Log3G10 (follow stream)"
        case display = "Display (IPP2)"
        var id: String { rawValue }
        var isLog3G10: Bool { self == .log3g10 }
        // The output whose Look we swap is no longer an operator guess (LCD vs
        // SDI). Prepare reads each camera's LIVESTREAM_MIRROR_SOURCE and resolves
        // the exact SDI_COLOR_SETTING param feeding that camera's stream, so the
        // swap always lands on the output the analyzer actually sees. See
        // CameraActor.readActiveMonitorTransform().
    }
    @Published var manualTransform: ManualTransform = .log3g10

    enum ManualSessionPhase: String, Equatable {
        case idle = "idle"
        case preparing = "preparing"
        case trimming = "trimming"
        case complete = "verified"
        case restoring = "restoring"
        case finished = "finished"
        case failed = "failed"
    }

    @Published var manualTargetMode: ManualTargetMode = .median
    @Published var manualTargetText: String = String(format: "%.1f", Log3G10.grayAnchorIRE)
    @Published var manualToleranceStops: Double = 0.10
    @Published var manualHoldSeconds: Double = 2.0
    @Published private(set) var manualPhase: ManualSessionPhase = .idle
    @Published private(set) var manualStatus: String = "Ready to capture a fixed target."
    @Published private(set) var manualTargetIRE: Double? = nil
    @Published private(set) var manualParticipantCount = 0
    @Published private(set) var manualMatchedCount = 0
    @Published private(set) var manualArraySpreadStops: Double? = nil
    @Published private(set) var manualCommonDriftStops: Double? = nil

    // MARK: Live Sphere Soak

    let soak = SoakRecorder()
    @Published var soakDuration: SoakDurationOption = .thirtyMinutes

    @Published private(set) var logLines: [BenchLogLine] = []

    private var loopTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var manualParticipantIDs: Set<UUID> = []
    private var manualStableSince: [UUID: Date] = [:]
    private var manualArrayStableSince: Date?
    private var manualRecentIRE: [UUID: [Double]] = [:]
    private var manualLastMeasurementAt: [UUID: Date] = [:]
    private var manualSavedTransforms: [UUID: MonitorTransformReading] = [:]
    private var manualChangedOutputs: Set<UUID> = []
    /// Participants whose masks we froze for the transform swap (reversed on end).
    private var manualFrozenNodes: Set<UUID> = []
    /// Single-operator guided flow: after a camera holds a match, focus jumps to
    /// the next unmatched camera (ID order) in fullscreen, and snaps back to any
    /// certified camera that later drifts out of tolerance.
    @Published var manualGuidedAdvance = true
    /// How long the focused camera must stay continuously matched before focus
    /// advances — breathing room to settle onto the true target with small
    /// re-adjustments instead of jumping the instant it first reads matched.
    @Published var manualAdvanceDwellSeconds: Double = 4.0
    /// When the focused camera began its current unbroken matched stretch (nil
    /// whenever it isn't matched). Drives the advance dwell.
    private var manualFocusDwellSince: Date?
    /// Cameras that have reached a held match and not since drifted out.
    private var manualCertified: Set<UUID> = []
    /// True once a session actually reached the Log3G10 transform stage. Lets the
    /// end message distinguish "nothing needed changing" from "blocked before we
    /// touched any output" (which must NOT claim the outputs are in Log3G10).
    private var manualEnteredTransformStage = false

    /// Stable ID-order key for guided advance (GA < GB < …; ip as a fallback).
    private func manualIDKey(_ node: CameraNode) -> String {
        node.status.displayID.isEmpty ? node.ip : node.status.displayID
    }

    /// Drop the focused camera's stream quality (and restore the previously
    /// lowered one) when the low-latency-focus option is on. Called each manual
    /// tick but only sends RCP on an actual change. `restoreOnly` on teardown.
    private func applyFocusStreamQuality(restoreOnly: Bool = false) {
        let target: UUID? = (restoreOnly || !lowerFocusStreamQuality) ? nil : fullScreenNodeID
        guard focusQualityNodeID != target else { return }
        if let prev = focusQualityNodeID, let n = nodes.first(where: { $0.id == prev }) {
            n.applyLiveQuality(n.desiredQuality)
        }
        if let tid = target, let n = nodes.first(where: { $0.id == tid }) {
            n.applyLiveQuality(Self.focusLowQuality)
            log("latency: \(manualIDKey(n)) stream → \(RCP2.livestreamQualityLabels[Self.focusLowQuality] ?? "?") while focused")
        }
        focusQualityNodeID = target
    }

    /// Move fullscreen focus (and selection) to a camera during the guided flow.
    private func focusManual(on node: CameraNode) {
        guard fullScreenNodeID != node.id else { return }
        fullScreenNodeID = node.id
        selectedNodeID = node.id
        manualFocusDwellSince = nil   // new camera starts its dwell fresh
        log("manual match: focus → \(manualIDKey(node))")
    }
    private var manualEndRequested = false
    private var manualEndMessage = "Manual Assist aborted by operator."
    private var manualEndWasFailure = false

    static let settleTimeout: TimeInterval = 10
    static let measureTimeout: TimeInterval = 6
    static let maxRounds = 16

    // MARK: - Stream auto-recovery
    /// Automatically restart a participant's livestream if it drops or stalls.
    /// Long matches outlive the MJPEG feed (idle timeout / transient network), and
    /// a 36-camera calibration must not depend on someone noticing a dead tile.
    @Published var autoRecoverStreams = true
    private var streamRetryCount: [UUID: Int] = [:]
    private var watchdogTask: Task<Void, Never>?
    /// A stream must be silent for this long before it's considered dead — well
    /// past normal frame jitter at ~20 fps.
    private static let streamStallTimeout: TimeInterval = 8.0
    /// And we never touch a stream until this long after it (re)started, so the
    /// enable delay and first-frame settle can never look like a stall. This also
    /// spaces retries: a still-dead camera is only restarted once per grace.
    private static let streamStartGrace: TimeInterval = 10.0

    init() {
        soak.onLog = { [weak self] line in self?.log(line) }
        soak.onDurationReached = { [weak self] in
            self?.stopSoak(reason: "duration reached")
        }
        startStreamWatchdog()
    }

    private func startStreamWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // 0.5 Hz — gentle
                guard let self else { return }
                self.recoverDeadStreams()
            }
        }
    }

    /// Restart the livestream on a camera that is *supposed* to be streaming but
    /// has genuinely gone dead. Deliberately conservative so it never fights
    /// normal startup or a healthy feed:
    ///   • only nodes with `streamingDesired`,
    ///   • only once the stream is `streamStartGrace` past its last (re)start
    ///     (so the ~0.7 s enable delay and first-frame settle are never a "stall"),
    ///   • dead = no frame for `streamStallTimeout` (or none ever, past grace),
    ///     or the reader reported a hard drop / frozen feed.
    /// Because a restart resets `lastStreamStartAt`, the grace also spaces retries
    /// (~one attempt per 10 s) — no separate backoff needed. Touches only the
    /// livestream: never seeds, masks, or the Log3G10 swap.
    func recoverDeadStreams() {
        guard autoRecoverStreams else { return }
        let now = Date()
        for node in nodes where node.connected && node.streamingDesired {
            // Still inside the post-(re)start settle window — leave it alone.
            if let started = node.lastStreamStartAt,
               now.timeIntervalSince(started) < Self.streamStartGrace { continue }

            let last = node.stream.stats.lastFrameAt
            let dead: Bool
            if let last {
                // Delivered frames before; dead only if they've stopped for a while
                // (a hard drop / frozen feed also means frames have stopped).
                dead = now.timeIntervalSince(last) > Self.streamStallTimeout
                    || !node.stream.isStreaming || node.streamStale
            } else {
                // Never delivered a frame and grace has elapsed — it's not coming.
                dead = true
            }

            if dead {
                let attempt = (streamRetryCount[node.id] ?? 0) + 1
                streamRetryCount[node.id] = attempt
                node.startStream()   // resets lastStreamStartAt → next attempt ≥ grace away
                log("auto-recover: \(node.ip) livestream dead — restart (attempt \(attempt))")
            } else if streamRetryCount[node.id] != nil {
                streamRetryCount[node.id] = nil   // healthy again
            }
        }
    }

    // MARK: - Discovery

    /// Zero-config discovery. PRIMARY is the RCP-native CAMINFO broadcast on
    /// UDP :1112 (field-notes rule 15) — subnet-agnostic, so it finds cameras
    /// across the L2 segment even when the swept /24 is wrong — bound to each
    /// detected interface so it egresses the right NIC (rule 16). The TCP
    /// :9998 connect-sweep FILLS IN cameras on UDP-blocked segments (a bare
    /// connect never upgrades to a WS → zero session slots). Both are merged.
    /// With an EMPTY subnet field the sweep targets are AUTO-DETECTED from this
    /// Mac's own interfaces; a non-empty field is a manual override — but a
    /// value that is a netmask or expands to no hosts is IGNORED (it would
    /// otherwise sweep a dead range and disable auto-detect, array-log finding
    /// 2026-07-20). Already-added bodies are skipped (rule 2).
    func discover() {
        guard !discovering else { return }
        discovering = true
        let source = sourceIP.trimmingCharacters(in: .whitespaces)
        var src = source.isEmpty ? nil : source
        // Guard: a source IP this Mac doesn't own binds every probe to a
        // dead local endpoint and the whole sweep fails SILENTLY (bench
        // finding 2026-07-17). Ignore it loudly instead.
        if let candidate = src, !LocalSubnets.ownIPv4Addresses().contains(candidate) {
            log("discovery: source IP \(candidate) is not an address on this Mac — IGNORING it for this sweep (rule 16 wants one of YOUR interface addresses, not the camera subnet)")
            src = nil
        }

        // Validate the manual subnet field. A netmask (255.255.255.0) or any
        // value that expands to no usable hosts must NOT be swept as a network:
        // it scans a dead range AND, because the field is non-empty, silently
        // disables the zero-config auto-detect that would have found the real
        // subnet (array-log finding 2026-07-20). Warn and fall through to auto.
        var manualCIDR = subnet.trimmingCharacters(in: .whitespaces)
        if !manualCIDR.isEmpty {
            if Subnet.looksLikeMask(manualCIDR) {
                log("discovery: subnet field \"\(manualCIDR)\" is a NETMASK, not a network — IGNORING it and auto-detecting instead (enter a subnet like 172.20.114.0/24, or leave it blank)")
                manualCIDR = ""
            } else if Subnet.hosts(from: manualCIDR).isEmpty {
                log("discovery: subnet field \"\(manualCIDR)\" expands to no usable hosts — IGNORING it and auto-detecting instead")
                manualCIDR = ""
            }
        }

        let known = Set(nodes.map(\.ip))
        Task {
            // Sweep targets + the interface source IPs to bind the broadcast to.
            var targets: [String] = []
            var broadcastSources: [String?] = []
            if manualCIDR.isEmpty {
                let detected = LocalSubnets.detect()
                targets = detected.map(\.cidr)
                broadcastSources = detected.map { Optional($0.address) }
                if detected.isEmpty {
                    log("discovery: no local IPv4 subnets detected — CAMINFO broadcast on the default route only")
                } else {
                    log("discovery: auto-detected " + detected.map {
                        "\($0.cidr) (\($0.interface) \($0.address), \($0.hostCount) hosts)"
                    }.joined(separator: ", ") + " — wide masks clamped to /24 around this host")
                }
            } else {
                targets = [manualCIDR]
            }
            // An explicit, validated source IP overrides per-interface binding.
            let bcastSources: [String?] = src != nil ? [src] : (broadcastSources.isEmpty ? [nil] : broadcastSources)

            var found: [DiscoveredCamera] = []
            func merge(_ cams: [DiscoveredCamera]) {
                for c in cams where !known.contains(c.ip) && !found.contains(where: { $0.ip == c.ip }) {
                    found.append(c)
                }
            }

            // 1) RCP-native CAMINFO broadcast FIRST (rule 15), per interface.
            for bsrc in bcastSources {
                log("discovery: CAMINFO broadcast\(bsrc.map { " via \($0)" } ?? "")")
                merge(await UDPDiscovery.discover(sourceIP: bsrc))
            }

            // 2) TCP :9998 sweep fills in UDP-blocked segments.
            for cidr in targets {
                let n = Subnet.hosts(from: cidr).count
                guard n > 0 else { continue }
                log("discovery: TCP sweep \(cidr) :9998 (\(n) hosts)")
                merge(await TCPScan.discover(cidr: cidr, sourceIP: src,
                                             skip: known.union(found.map(\.ip))))
            }

            // Sim convenience: a :9998 listener on plain 127.0.0.1 is always
            // the simulator (real bodies never live there) — one free probe
            // makes the no-sudo single-sim case zero-config too.
            if !known.contains("127.0.0.1"), !found.contains(where: { $0.ip == "127.0.0.1" }) {
                let simHits = await TCPScan.discover(cidr: "127.0.0.1/32", sourceIP: nil,
                                                     skip: known.union(found.map(\.ip)))
                if !simHits.isEmpty {
                    log("discovery: simulator detected on 127.0.0.1")
                    merge(simHits)
                }
            }

            discovered = found
            discovering = false
            log("discovery: \(found.count) new camera(s)")
        }
    }

    func addDiscovered(_ cam: DiscoveredCamera) {
        addNode(ip: cam.ip, label: cam.label)
        discovered.removeAll { $0.ip == cam.ip }
    }

    func addAllDiscovered() {
        for cam in discovered { addNode(ip: cam.ip, label: cam.label) }
        discovered.removeAll()
    }

    func dismissDiscovered() { discovered.removeAll() }

    // MARK: - Livestream quality

    /// Push the array-wide quality to every connected body, read-back verified
    /// per camera (CameraActor logs any that don't echo the value).
    func setQualityAll() {
        let q = arrayQuality
        log("array quality: LIVESTREAM_QUALITY \(q) (\(RCP2.livestreamQualityLabels[q] ?? "?")) → \(nodes.count) camera(s), verified per body")
        for node in nodes { node.applyQuality(q) }
    }

    // MARK: - Sphere seeding (operator click → array-wide signature)

    /// The operator clicked the sphere center on `node` (normalized frame
    /// coords). Begin a PENDING mask the operator sizes and approves — nothing
    /// locks or broadcasts until Approve (see `approveSeed`).
    func seedSphere(_ node: CameraNode, normX: Double, normY: Double) {
        let nx = min(max(normX, 0), 1), ny = min(max(normY, 0), 1)
        node.beginSeed(normX: nx, normY: ny)
        log("seed: \(node.displayName) center @ (\(String(format: "%.3f", nx)), \(String(format: "%.3f", ny))) — size the mask, then Approve")
    }

    /// Approve the pending mask on `node`: lock it and broadcast its sphere
    /// signature to the rest of the array so the others auto-lock the matching
    /// object instead of the top-vote blob.
    func approveSeed(_ node: CameraNode) {
        guard let signature = node.approveSeed() else {
            log("seed: nothing to approve on \(node.displayName)")
            return
        }
        broadcastSeedSignature(signature, from: node, verb: "approved")
    }

    /// One-click accept of a camera's current auto-detected mask (from the tile,
    /// no fullscreen). Freezes it as the seed and broadcasts the signature.
    func acceptAutoMask(_ node: CameraNode) {
        guard let signature = node.acceptCurrentMask() else {
            log("seed: no mask to accept on \(node.displayName)")
            return
        }
        broadcastSeedSignature(signature, from: node, verb: "auto-mask accepted")
    }

    private func broadcastSeedSignature(_ signature: SphereSignature, from node: CameraNode, verb: String) {
        var applied = 0
        for other in nodes where other.id != node.id {
            other.applySignature(signature)
            applied += 1
        }
        log("seed: \(node.displayName) \(verb) — signature (r/w=\(String(format: "%.3f", signature.radiusRatio)), chroma=\(String(format: "%.4f", signature.chroma))) to \(applied) other camera(s)")
    }

    /// Cycle the fullscreen camera to the next/prev body in ID order — hands-free
    /// seeding without minimize + double-click. delta +1 = next, -1 = previous.
    func fullscreenStep(_ delta: Int) {
        guard let current = fullScreenNodeID, !nodes.isEmpty else { return }
        let ordered = nodes.sorted { manualIDKey($0) < manualIDKey($1) }
        guard let idx = ordered.firstIndex(where: { $0.id == current }) else { return }
        let next = ordered[(idx + delta + ordered.count) % ordered.count]
        fullScreenNodeID = next.id
        selectedNodeID = next.id
    }

    func cancelSeed(_ node: CameraNode) { node.cancelSeed() }

    // MARK: - Membership

    /// Manual entry — the fallback when discovery can't see the camera
    /// (cross-subnet routes, unusual NIC setups).
    func addCamera() {
        let ip = newIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        newIP = ""
        if ip.hasSuffix(".0") {
            // Bench finding 2026-07-17: "127.0.0.0" got added as a camera.
            log("warning: \(ip) looks like a NETWORK address, not a camera (did you mean the camera's own IP, e.g. \(ip.dropLast())1?) — adding anyway")
        }
        addNode(ip: ip, label: "")
    }

    private func addNode(ip: String, label: String) {
        guard !nodes.contains(where: { $0.ip == ip }) else { return }
        let node = CameraNode(ip: ip)
        node.onLog = { [weak self] line in self?.log(line) }
        node.diagnosticsEnabled = logSphereDiagnostics
        node.stream.dropToLatestFrame = dropStaleFrames
        if soak.isRecording { node.attachSoakRecorder(soak) }
        nodes.append(node)
        if selectedNodeID == nil { selectedNodeID = node.id }
        log("added \(ip)\(label.isEmpty ? "" : " (\(label))")")
        // Auto-connect on add so the array comes up hands-free — discovered or
        // manual, no separate Connect All step. Manual Assist owns reversible
        // output state, so never open new sessions mid-session (rule 2/11).
        if !manualSessionActive {
            let src = sourceIP.trimmingCharacters(in: .whitespaces)
            node.connect(sourceIP: src.isEmpty ? nil : src)
        }
    }

    func removeCamera(_ node: CameraNode) {
        if fullScreenNodeID == node.id { fullScreenNodeID = nil }
        guard !manualSessionActive else {
            log("remove camera: blocked while Manual Assist owns reversible output state — Finish or Abort first")
            return
        }
        node.attachSoakRecorder(nil)
        node.disconnect()
        nodes.removeAll { $0.id == node.id }
        if selectedNodeID == node.id { selectedNodeID = nodes.first?.id }
        log("removed \(node.ip)")
    }

    func connectAll() {
        guard !manualSessionActive else { return }
        let src = sourceIP.trimmingCharacters(in: .whitespaces)
        let s = src.isEmpty ? nil : src
        // Cameras auto-connect on add, so most are usually already up — Connect
        // All then reconnects anything down and revives the rest, and reports
        // what it did so the button isn't a silent no-op.
        var connecting = 0, revived = 0
        for node in nodes {
            if node.connected { node.refresh(); revived += 1 }
            else { node.connect(sourceIP: s); connecting += 1 }
        }
        log("connect all: \(connecting) connecting, \(revived) already up (revived)")
    }

    func disconnectAll() {
        guard !manualSessionActive else {
            log("disconnect all: blocked while Manual Assist owns reversible output state — Finish or Abort first")
            return
        }
        stopMatch()
        if soak.isRecording { stopSoak(reason: "array disconnected") }
        for node in nodes { node.disconnect() }
    }

    func streamAll() {
        guard !manualSessionActive else { return }
        for node in nodes where node.connected && !node.stream.isStreaming {
            node.startStream()
        }
    }

    /// Revive dropped RCP sessions and restart timed-out livestreams WITHOUT
    /// tearing anything down — deliberately NOT gated on manualSessionActive so a
    /// mid-calibration drop (MJPEG idle-timeout on a long match) recovers in
    /// place. A 36-camera match must never have to restart from scratch. Touches
    /// only connectivity: seeds, frozen masks, and the Log3G10 swap are left
    /// exactly as they were, and only cameras whose stream is actually down are
    /// touched (healthy streams don't blip).
    func reconnectStreams() {
        let src = sourceIP.trimmingCharacters(in: .whitespaces)
        let s = src.isEmpty ? nil : src
        var reconnected = 0, restreamed = 0
        for node in nodes {
            if !node.connected {
                // Session fully dropped (camera == nil) — rebuild it. Its seed is
                // already gone in this case and will need re-placing.
                node.connect(sourceIP: s)
                node.startStream()
                reconnected += 1
            } else if !node.stream.isStreaming {
                node.refresh()        // revive the RCP session
                node.startStream()    // re-enable + reopen the MJPEG stream
                restreamed += 1
            }
        }
        log("reconnect: \(reconnected) session(s) rebuilt, \(restreamed) livestream(s) restarted, seeds/transform preserved")
    }

    /// Capability gate + APERTURE subscription on every connected body — one
    /// operator action for the whole array, one body at a time (serialized so
    /// a wedge is attributable to a specific camera; rule 11).
    func prepareAll() {
        guard !manualSessionActive else { return }
        Task {
            for node in nodes where node.connected {
                await node.prepare()
            }
            log("array prepare complete — e-iris: " +
                nodes.filter(\.eIris).map(\.ip).joined(separator: ", "))
        }
    }

    /// One deliberate rule-11 array action. Each body is processed serially so
    /// a bad/unverified parameter remains attributable to one camera session.
    /// Prior display presets captured by Set Log3G10, keyed by node —
    /// what Restore Presets puts back. In-memory only; every captured value
    /// is also logged, so a crashed session can be recovered from the log.
    private var savedLoopTransforms: [UUID: MonitorTransformReading] = [:]
    @Published private(set) var savedPresetCount = 0

    func setLog3G10OnArray() {
        guard !loopRunning, !manualSessionActive else { return }
        Task {
            let targets = nodes.filter(\.connected)
            guard !targets.isEmpty else {
                log("set Log3G10: no connected cameras")
                return
            }
            log("set Log3G10: starting on \(targets.count) camera(s) — output-side")
            var confirmed = 0
            for node in targets {
                guard let camera = node.camera else { continue }
                // Capture the pre-swap preset FIRST so Restore Presets can
                // put the operator's monitor path back after matching.
                let before = await camera.readActiveMonitorTransform()
                if let value = before.presetValue, !before.parameterID.isEmpty,
                   value != RCP2.log3G10DisplayPresetValue,
                   savedLoopTransforms[node.id] == nil {
                    savedLoopTransforms[node.id] = before
                    log("set Log3G10: [\(node.ip)] saved prior preset \(before.parameterID) = \(value) (\(RCP2.displayPresetLabels[value] ?? "?")) for restore")
                }
                let ok = await camera.setActiveMonitorLog3G10()
                if ok { confirmed += 1 }
                log("set Log3G10: [\(node.ip)] \(ok ? "confirmed" : "FAILED / unconfirmed")")
            }
            savedPresetCount = savedLoopTransforms.count
            log("set Log3G10: complete — \(confirmed)/\(targets.count) confirmed")
        }
    }

    /// Array-wide undo of Set Log3G10: put every captured pre-swap preset
    /// back. Per-camera restore is conservative (CameraActor refuses when
    /// the mirrored output changed or a third preset appeared mid-session) —
    /// refused bodies KEEP their saved value so the operator can retry.
    func restorePresetsOnArray() {
        guard !loopRunning, !manualSessionActive, !savedLoopTransforms.isEmpty else { return }
        Task {
            log("restore presets: starting on \(savedLoopTransforms.count) camera(s)")
            var restored = 0
            for node in nodes {
                guard let saved = savedLoopTransforms[node.id] else { continue }
                guard node.connected, let camera = node.camera else {
                    log("restore presets: [\(node.ip)] SKIPPED — not connected (saved value retained)")
                    continue
                }
                let ok = await camera.restoreMonitorTransform(saved)
                if ok {
                    savedLoopTransforms.removeValue(forKey: node.id)
                    restored += 1
                }
                log("restore presets: [\(node.ip)] \(ok ? "restored" : "REFUSED / failed — saved value retained")")
            }
            savedPresetCount = savedLoopTransforms.count
            log("restore presets: complete — \(restored) restored, \(savedLoopTransforms.count) outstanding")
        }
    }

    // MARK: - Manual Assist

    var manualSessionActive: Bool {
        switch manualPhase {
        case .preparing, .trimming, .complete, .restoring: return true
        case .idle, .finished, .failed: return false
        }
    }

    var workflowBusy: Bool { loopRunning || manualSessionActive }

    var manualParticipants: [CameraNode] {
        nodes.filter { manualParticipantIDs.contains($0.id) }
    }

    var manualCustomTargetIRE: Double? {
        guard let value = Double(manualTargetText.trimmingCharacters(in: .whitespaces)),
              value > 0, value < 100,
              Log3G10.linearize(value / 100.0) > 0 else { return nil }
        return value
    }

    func isManualParticipant(_ node: CameraNode) -> Bool {
        manualParticipantIDs.contains(node.id)
    }

    /// Start a human-in-the-loop match session. Unlike the electronic loop,
    /// this deliberately ignores APERTURE_CONTROL and never sends APERTURE.
    /// Every connected + streaming participant must have a trusted sphere lock.
    func startManualMatch() {
        guard manualTask == nil, !loopRunning, !manualSessionActive else { return }
        guard manualTargetMode != .custom || manualCustomTargetIRE != nil else {
            manualPhase = .failed
            manualStatus = "Custom target must be a valid Log3G10 IRE between 0 and 100."
            return
        }

        matchWorkflow = .manual
        manualEndRequested = false
        manualEndWasFailure = false
        manualEndMessage = "Manual Assist aborted by operator."
        manualTargetIRE = nil
        manualParticipantCount = 0
        manualMatchedCount = 0
        manualArraySpreadStops = nil
        manualCommonDriftStops = nil
        for node in nodes { node.fastAnalysis = false }   // back to the 3 Hz cadence
        manualParticipantIDs.removeAll()
        manualStableSince.removeAll()
        manualArrayStableSince = nil
        manualRecentIRE.removeAll()
        manualLastMeasurementAt.removeAll()
        manualSavedTransforms.removeAll()
        manualChangedOutputs.removeAll()
        manualFrozenNodes.removeAll()
        manualCertified.removeAll()
        manualEnteredTransformStage = false
        manualFocusDwellSince = nil
        for node in nodes { node.manualMatch = ManualMatchInfo(); node.focusedTrim = false }

        manualPhase = .preparing
        manualStatus = "Checking streams, sphere locks, and mirrored outputs…"
        manualTask = Task { await runManualMatchSession() }
    }

    func abortManualMatch() {
        guard manualTask != nil, manualSessionActive else { return }
        manualEndWasFailure = false
        manualEndMessage = "Manual Assist aborted by operator."
        manualEndRequested = true
        manualPhase = .restoring
        manualStatus = "Stopping guidance and restoring saved output presets…"
        log("manual match: abort requested")
    }

    func finishManualMatch() {
        guard manualTask != nil, manualPhase == .complete else { return }
        manualEndWasFailure = false
        manualEndMessage = "Manual Assist complete."
        manualEndRequested = true
        manualPhase = .restoring
        manualStatus = "Match verified — restoring saved output presets…"
        log("manual match: finish requested")
    }

    /// End-of-set action: capture the report (stills are grabbed NOW, while the
    /// array is still in Log3G10 with matched overlays live), then restore the
    /// saved output presets. One button for the single-operator flow.
    /// Capture the report then restore — available whenever a match is live
    /// (trimming OR verified), because the operator should ALWAYS be able to
    /// record the array state: a deliberately-different exposure on one camera
    /// never reaches an all-green "complete", but it still needs a report.
    /// Cancelling the save dialog leaves the session running (no restore).
    func finishManualMatchReport() {
        guard manualTask != nil, manualPhase == .trimming || manualPhase == .complete else { return }
        let ordered = manualParticipants.sorted { manualIDKey($0) < manualIDKey($1) }
        let model = MatchReport.model(cameras: ordered,
                                      target: manualTargetIRE ?? 0,
                                      toleranceStops: manualToleranceStops,
                                      spreadStops: manualArraySpreadStops)
        guard let url = MatchReport.promptAndWrite(model) else {
            log("manual match: report save cancelled — session left running")
            return
        }
        log("manual match: report saved → \(url.lastPathComponent)")
        soak.recordMatchEvent("manual_match_report", detail: url.path)
        // Restore now (works from trimming or complete).
        manualEndWasFailure = false
        manualEndMessage = (manualPhase == .complete) ? "Manual Assist complete." : "Manual Assist ended by operator."
        manualEndRequested = true
        manualPhase = .restoring
        manualStatus = "Report saved — restoring saved output presets…"
        log("manual match: finish + report requested")
    }

    private func runManualMatchSession() async {
        // Disconnected nodes are outside the active array, but every connected
        // body must stream and lock before capture. Never silently certify a
        // partial connected array.
        let parts = nodes.filter(\.connected)
        guard parts.count >= 2 else {
            await failManualMatch("Need at least two connected cameras for Manual Assist.")
            return
        }
        let unstreamed = parts.filter { !$0.stream.isStreaming }
        guard unstreamed.isEmpty else {
            await failManualMatch("Start the livestream on every connected camera: \(unstreamed.map(\.ip).joined(separator: ", ")).")
            return
        }
        let unlocked = parts.filter { $0.sphere.phase != .locked || $0.sphere.heroIRE == nil }
        guard unlocked.isEmpty else {
            await failManualMatch("Sphere lock required on every streaming camera: \(unlocked.map(\.ip).joined(separator: ", ")).")
            return
        }

        manualParticipantIDs = Set(parts.map(\.id))
        for node in parts { node.fastAnalysis = true }   // human-in-the-loop fast path
        manualParticipantCount = parts.count
        if !manualParticipantIDs.contains(selectedNodeID ?? UUID()) {
            selectedNodeID = parts.first?.id
        }
        for node in parts {
            node.manualMatch.phase = .acquiring
            node.manualMatch.detail = "capturing output state"
        }
        log("manual match: preparing \(parts.count) camera(s); APERTURE commands disabled")

        // Log3G10 · LCD / · SDI swap that output's "Look" (SDI_COLOR_SETTING) to
        // COLOR_SETTING_LOG for the match, then restore the original (3D LUT /
        // Custom Display) on Finish/Abort. Display (IPP2) leaves everything
        // untouched. The livestream mirror source is READ-ONLY status, so the
        // operator picks the output the stream is actually mirroring; we warn if
        // the two don't match.
        if manualTransform.isLog3G10 {
            manualEnteredTransformStage = true
            // Freeze every participant's mask BEFORE the swap. The flat/desaturated
            // Log3G10 look breaks appearance-based detection, so a non-seeded lock
            // coasts then times out (~3 s) and the all-camera baseline gate fails —
            // exactly the 2026-07-21 revert. Frozen masks hold geometry and keep
            // measuring hero IRE at the fixed ROI through the appearance change.
            // Reversed in closeManualMatch(). Operator seeds are already frozen and
            // are left untouched.
            for node in parts where node.freezeTransformLock() {
                manualFrozenNodes.insert(node.id)
            }
            if !manualFrozenNodes.isEmpty {
                log("manual match: froze \(manualFrozenNodes.count) auto-locked mask(s) to hold through the Log3G10 swap")
            }
            manualStatus = "Setting Log3G10 on each camera's mirrored output…"
            for node in parts {
                guard !manualEndRequested else { await closeManualMatch(); return }
                guard let camera = node.camera else {
                    await failManualMatch("Camera actor unavailable for \(node.ip).")
                    return
                }
                // Resolve the exact output feeding THIS camera's livestream mirror
                // (reads LIVESTREAM_MIRROR_SOURCE, picks the advertised
                // SDI_COLOR_SETTING param, and reads its current Look). This is the
                // fix for the 2026-07-20 failure: we no longer guess LCD-vs-SDI, so
                // the swap always lands on the output the analyzer actually sees.
                let reading = await camera.readActiveMonitorTransform()
                guard !reading.parameterID.isEmpty, let before = reading.presetValue else {
                    await failManualMatch("Cannot resolve/read the Look on \(node.ip)'s livestream mirror output; no output left in an unknown state.")
                    return
                }
                manualSavedTransforms[node.id] = reading
                // Already Log3G10? leave it (and don't mark it changed).
                guard before != RCP2.log3G10DisplayPresetValue else { continue }
                manualChangedOutputs.insert(node.id)
                let ok = await camera.setMonitorDisplayPreset(
                    parameterID: reading.parameterID, value: RCP2.log3G10DisplayPresetValue,
                    reason: "manual match Log3G10")
                guard ok else {
                    await failManualMatch("Could not set Log3G10 on \(node.ip) (\(reading.parameterID)).")
                    return
                }
            }
        } else {
            log("manual match: Display (IPP2) — outputs untouched, 18% gray anchored at \(String(format: "%.1f", Self.ipp2GrayAnchorIRE)) IRE")
        }

        guard !manualEndRequested else { await closeManualMatch(); return }
        manualStatus = "Waiting for post-transform frames…"
        let freshEpoch = Date()
        let fresh = await waitFreshMeasurements(parts, after: freshEpoch)
        guard !manualEndRequested else { await closeManualMatch(); return }
        guard fresh else {
            await failManualMatch("Livestream measurements did not refresh after the output change.")
            return
        }

        manualStatus = "Capturing stable sphere baselines…"
        guard let baselines = await captureManualBaselines(parts) else {
            if manualEndRequested { await closeManualMatch() }
            else { await failManualMatch("Could not capture stable locked-sphere baselines on every camera.") }
            return
        }
        guard !manualEndRequested else { await closeManualMatch(); return }

        let target: Double
        switch manualTargetMode {
        case .median:
            target = median(Array(baselines.values)) ?? 0
        case .gray18:
            // 18% gray anchors at 33.3 IRE in Log3G10, 42.3 IRE in IPP2.
            target = manualTransform.isLog3G10 ? Log3G10.grayAnchorIRE : Self.ipp2GrayAnchorIRE
        case .custom:
            target = manualCustomTargetIRE ?? 0
        }
        if manualTransform.isLog3G10 {
            guard target > 0, Log3G10.linearize(target / 100.0) > 0 else {
                await failManualMatch("Captured target is outside the usable Log3G10 range.")
                return
            }
        } else {
            guard target > 0, target < 100 else {
                await failManualMatch("Captured target is outside the usable 0–100 IRE range.")
                return
            }
        }

        manualTargetIRE = target
        for node in parts {
            let baseline = baselines[node.id]
            node.manualMatch = ManualMatchInfo(
                phase: .acquiring,
                baselineIRE: baseline,
                currentIRE: baseline,
                targetIRE: target,
                correctionStops: baseline.map { Log3G10.stops(between: target, and: $0) },
                deltaIRE: baseline.map { $0 - target },
                stability: 0,
                detail: "fixed target captured")
        }
        manualPhase = .trimming
        manualStatus = String(format: "Target locked at %.1f IRE — select a camera and trim its lens.", target)
        log(String(format: "manual match: START — %d cameras, fixed target %.2f IRE, tolerance ±%.3f stop, hold %.1fs",
                   parts.count, target, manualToleranceStops, manualHoldSeconds))
        soak.recordMatchEvent("manual_match_start",
                              detail: String(format: "%d cameras; target %.2f IRE; tolerance %.3f stop",
                                             parts.count, target, manualToleranceStops))

        while !manualEndRequested {
            updateManualMatch(parts)
            try? await Task.sleep(nanoseconds: 50_000_000)   // 20 Hz UI/guidance loop
        }
        await closeManualMatch()
    }

    /// A short rolling capture makes the fixed baseline resistant to one JPEG
    /// or detector outlier without pretending the independent streams are
    /// frame-synchronous.
    private func captureManualBaselines(_ parts: [CameraNode]) async -> [UUID: Double]? {
        var samples: [UUID: [Double]] = [:]
        var lastSeen: [UUID: Date] = [:]
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !manualEndRequested {
            for node in parts {
                guard node.sphere.phase == .locked,
                      let ire = node.sphere.heroIRE,
                      let measuredAt = node.sphere.measuredAt,
                      lastSeen[node.id] != measuredAt else { continue }
                samples[node.id, default: []].append(ire)
                lastSeen[node.id] = measuredAt
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !manualEndRequested,
              parts.allSatisfy({ (samples[$0.id]?.count ?? 0) >= 2 }) else { return nil }

        var result: [UUID: Double] = [:]
        for node in parts {
            guard let values = samples[node.id], let value = median(values) else { return nil }
            result[node.id] = value
            manualRecentIRE[node.id] = Array(values.suffix(5))
            manualLastMeasurementAt[node.id] = lastSeen[node.id]
        }
        return result
    }

    private func updateManualMatch(_ parts: [CameraNode]) {
        guard let target = manualTargetIRE else { return }
        let now = Date()

        // Only the fullscreen-focused camera runs the ~14 Hz frozen fast path.
        for node in parts { node.focusedTrim = (node.id == fullScreenNodeID) }
        applyFocusStreamQuality()

        for node in parts {
            let measurementFresh: Bool
            if let measuredAt = node.sphere.measuredAt {
                measurementFresh = now.timeIntervalSince(measuredAt) <= 1.5
                if measurementFresh, measuredAt != manualLastMeasurementAt[node.id],
                   let ire = node.sphere.heroIRE {
                    var values = manualRecentIRE[node.id, default: []]
                    values.append(ire)
                    // The camera a hand is actively on (fullscreen focus) uses a
                    // median-of-2 — near-raw, minimal lag — because its frozen ROI
                    // has little detection scatter. Every other participant keeps
                    // median-of-3 to reject single-frame outliers while it holds.
                    // Latency is the enemy of a hand on an iris ring.
                    let window = (node.id == fullScreenNodeID) ? 2 : 3
                    if values.count > window { values.removeFirst(values.count - window) }
                    manualRecentIRE[node.id] = values
                    manualLastMeasurementAt[node.id] = measuredAt
                }
            } else {
                measurementFresh = false
            }

            guard node.connected, node.stream.isStreaming,
                  node.sphere.phase == .locked, measurementFresh,
                  let current = median(manualRecentIRE[node.id] ?? []),
                  let baseline = node.manualMatch.baselineIRE else {
                manualStableSince.removeValue(forKey: node.id)
                node.manualMatch.phase = .unavailable
                node.manualMatch.stability = 0
                node.manualMatch.detail = "sphere lock or fresh stream measurement lost"
                continue
            }

            let correction = Log3G10.stops(between: target, and: current)
            guard correction.isFinite else {
                manualStableSince.removeValue(forKey: node.id)
                node.manualMatch.phase = .unavailable
                node.manualMatch.detail = "invalid Log3G10 measurement"
                continue
            }

            let wasMatched = node.manualMatch.phase == .matched
            node.manualMatch.currentIRE = current
            node.manualMatch.targetIRE = target
            node.manualMatch.correctionStops = correction
            node.manualMatch.deltaIRE = current - target
            node.manualMatch.baselineIRE = baseline
            node.manualMatch.toleranceStops = manualToleranceStops

            if abs(correction) <= manualToleranceStops {
                let since = manualStableSince[node.id] ?? now
                manualStableSince[node.id] = since
                let progress = min(1, now.timeIntervalSince(since) / max(0.1, manualHoldSeconds))
                node.manualMatch.stability = progress
                node.manualMatch.phase = progress >= 1 ? .matched : .hold
                node.manualMatch.detail = progress >= 1
                    ? "stable inside tolerance"
                    : String(format: "hold steady %.1fs", max(0, manualHoldSeconds - now.timeIntervalSince(since)))
            } else if wasMatched && abs(correction) <= manualToleranceStops * 1.25 {
                // Small hysteresis prevents a certified camera flickering at
                // the exact tolerance boundary; array verification still uses
                // the strict tolerance below.
                node.manualMatch.stability = 1
                node.manualMatch.phase = .matched
                node.manualMatch.detail = "matched (edge hysteresis)"
            } else {
                manualStableSince.removeValue(forKey: node.id)
                node.manualMatch.stability = 0
                node.manualMatch.phase = correction > 0 ? .open : .close
                node.manualMatch.detail = correction > 0
                    ? String(format: "open iris %.2f stop", abs(correction))
                    : String(format: "close iris %.2f stop", abs(correction))
            }
        }

        manualMatchedCount = parts.filter { $0.manualMatch.phase == .matched }.count

        // --- Guided auto-advance (single operator, fullscreen) ---
        // A camera is "certified" once it holds a match. If a certified camera
        // later leaves tolerance (phase OPEN/CLOSE/NO SIGNAL — i.e. past the
        // matched hysteresis), snap focus back to the earliest such camera.
        // Otherwise, once the focused camera is certified, jump to the next
        // uncertified, available camera in ID order.
        if manualGuidedAdvance, manualSessionActive, fullScreenNodeID != nil {
            var justDrifted: [CameraNode] = []
            for node in parts {
                if node.manualMatch.phase == .matched {
                    manualCertified.insert(node.id)
                } else if manualCertified.contains(node.id),
                          node.manualMatch.phase == .open
                            || node.manualMatch.phase == .close
                            || node.manualMatch.phase == .unavailable {
                    manualCertified.remove(node.id)
                    justDrifted.append(node)
                }
            }
            let ordered = parts.sorted { manualIDKey($0) < manualIDKey($1) }

            // Dwell: track how long the focused camera has held an unbroken match.
            let focus = parts.first(where: { $0.id == fullScreenNodeID })
            if focus?.manualMatch.phase == .matched {
                if manualFocusDwellSince == nil { manualFocusDwellSince = now }
            } else {
                manualFocusDwellSince = nil
            }
            let dwellMet = manualFocusDwellSince
                .map { now.timeIntervalSince($0) >= manualAdvanceDwellSeconds } ?? false

            if let drifted = justDrifted.min(by: { manualIDKey($0) < manualIDKey($1) }) {
                // Snap-back is immediate — a certified camera that slipped needs
                // attention now, regardless of the forward dwell.
                focusManual(on: drifted)
            } else if let focus, manualCertified.contains(focus.id), dwellMet,
                      let next = ordered.first(where: {
                          !manualCertified.contains($0.id) && $0.manualMatch.phase != .unavailable
                      }) {
                focusManual(on: next)
            }
        }

        let liveIRE = parts.compactMap { $0.manualMatch.currentIRE }.sorted()
        if let lo = liveIRE.first, let hi = liveIRE.last, liveIRE.count >= 2 {
            let spread = abs(Log3G10.stops(between: lo, and: hi))
            manualArraySpreadStops = spread.isFinite ? spread : nil
        } else {
            manualArraySpreadStops = nil
        }

        updateManualDrift(parts)
        let unavailable = parts.filter { $0.manualMatch.phase == .unavailable }
        let allStrictlyInside = parts.allSatisfy { node in
            guard node.manualMatch.phase != .unavailable,
                  let correction = node.manualMatch.correctionStops else { return false }
            return abs(correction) <= manualToleranceStops
        }

        if allStrictlyInside, manualCommonDriftStops == nil {
            let since = manualArrayStableSince ?? now
            manualArrayStableSince = since
            if now.timeIntervalSince(since) >= manualHoldSeconds {
                if manualPhase != .complete {
                    manualPhase = .complete
                    manualStatus = "Array verified simultaneously — Finish & Restore when ready."
                    log("manual match: VERIFY PASS — every participant held the fixed target")
                    soak.recordMatchEvent("manual_match_verified",
                                          finalSpreadStops: manualArraySpreadStops,
                                          detail: "all cameras inside tolerance")
                }
            } else if manualPhase != .complete {
                manualStatus = String(format: "All cameras in target — hold %.1fs for array verification.",
                                      max(0, manualHoldSeconds - now.timeIntervalSince(since)))
            }
        } else {
            manualArrayStableSince = nil
            if manualPhase == .complete {
                manualPhase = .trimming
                manualStatus = "Verification reopened — one or more cameras left the target."
                log("manual match: verification reopened")
            } else if !unavailable.isEmpty {
                manualStatus = "SIGNAL LOST — reacquire sphere lock on: \(unavailable.map(\.ip).joined(separator: ", "))."
            } else if let drift = manualCommonDriftStops {
                manualStatus = String(format: "GLOBAL LIGHTING DRIFT %+.2f stop — pause trim and inspect the stage.", drift)
            } else {
                manualStatus = String(format: "%d/%d matched — trim the selected camera toward the fixed target.",
                                      manualMatchedCount, manualParticipantCount)
            }
        }
    }

    /// Cameras not selected and not yet in their HOLD/MATCHED gate act as
    /// independent drift sentinels relative to their own captured baselines.
    private func updateManualDrift(_ parts: [CameraNode]) {
        let activeID = selectedNodeID
        let shifts = parts.compactMap { node -> Double? in
            guard node.id != activeID,
                  node.manualMatch.phase == .open || node.manualMatch.phase == .close,
                  let baseline = node.manualMatch.baselineIRE,
                  let current = node.manualMatch.currentIRE else { return nil }
            let shift = Log3G10.stops(between: baseline, and: current)
            return shift.isFinite ? shift : nil
        }
        guard shifts.count >= 2, let common = median(shifts), abs(common) >= 0.15 else {
            manualCommonDriftStops = nil
            return
        }
        let aligned = shifts.filter {
            abs($0) >= 0.075 && (($0 > 0) == (common > 0))
        }.count
        manualCommonDriftStops = aligned >= max(2, (shifts.count + 1) / 2) ? common : nil
    }

    private func failManualMatch(_ message: String) async {
        manualEndWasFailure = true
        manualEndMessage = message
        manualEndRequested = true
        log("manual match: BLOCKED — \(message)")
        await closeManualMatch()
    }

    private func closeManualMatch() async {
        manualPhase = .restoring
        manualStatus = "Restoring saved output presets…"
        var restored = 0
        var failed: [String] = []
        for node in nodes where manualChangedOutputs.contains(node.id) {
            guard let camera = node.camera, let saved = manualSavedTransforms[node.id] else {
                failed.append(node.ip)
                continue
            }
            // Restore the exact Look param we swapped (LCD or SDI) to its
            // saved value — Custom Display / 3D LUT / etc.
            if await camera.restoreColorSetting(saved) {
                restored += 1
            } else {
                failed.append(node.ip)
            }
        }

        let changed = manualChangedOutputs.count
        let restoreText: String
        if changed > 0 {
            restoreText = "Restored \(restored)/\(changed) changed output preset(s)."
        } else if manualEnteredTransformStage {
            // Reached the swap stage but every mirrored output was already at
            // Log3G10, so nothing needed changing.
            restoreText = "Outputs were already Log3G10."
        } else {
            // Blocked in preflight — no output was ever touched. Say nothing about
            // Log3G10 so it can't read as "outputs are stuck in Log3G10".
            restoreText = "No output presets were changed."
        }
        let failureText = failed.isEmpty ? "" : " Restore requires attention: \(failed.joined(separator: ", "))."
        manualStatus = "\(manualEndMessage) \(restoreText)\(failureText)"
        manualPhase = (manualEndWasFailure || !failed.isEmpty) ? .failed : .finished
        log("manual match: END — \(manualStatus)")
        soak.recordMatchEvent("manual_match_end",
                              finalSpreadStops: manualArraySpreadStops,
                              detail: manualStatus)

        // Release the masks we froze for the swap so normal tracking resumes.
        for node in nodes where manualFrozenNodes.contains(node.id) {
            node.unfreezeTransformLock()
        }
        for node in nodes { node.focusedTrim = false }
        applyFocusStreamQuality(restoreOnly: true)   // restore any lowered stream

        manualSavedTransforms.removeAll()
        manualChangedOutputs.removeAll()
        manualFrozenNodes.removeAll()
        manualCertified.removeAll()
        manualEnteredTransformStage = false
        manualFocusDwellSince = nil
        manualEndRequested = false
        manualEndWasFailure = false
        manualTask = nil
    }

    private func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    // MARK: - Live Sphere Soak

    func startSoak() {
        guard !soak.isRecording else { return }
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "r3diris_sphere_soak_\(stamp).csv"
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                try self.soak.start(csvURL: url, duration: self.soakDuration)
                for node in self.nodes { node.attachSoakRecorder(self.soak) }
                self.log("sphere soak: armed for \(self.nodes.count) camera(s)")
            } catch {
                self.log("sphere soak: START FAILED — \(error.localizedDescription)")
            }
        }
    }

    func stopSoak() {
        stopSoak(reason: "stopped by operator")
    }

    private func stopSoak(reason: String) {
        guard soak.isRecording else { return }
        // Detach first: an analysis completion already queued on MainActor can
        // no longer race the file close.
        for node in nodes { node.attachSoakRecorder(nil) }
        guard let summary = soak.stop(reason: reason) else { return }
        log("sphere soak summary — CSV: \(summary.csvURL.path)")
        log("sphere soak summary — report: \(summary.summaryURL.path)")
        for line in summary.lines { log("SOAK | \(line)") }
    }

    var selectedNode: CameraNode? {
        nodes.first { $0.id == selectedNodeID }
    }

    // MARK: - Iris Match: bulk T-stop push

    var linkStopX10: Int? {
        guard let v = Double(linkStopText.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return Int((v * 10).rounded())
    }

    /// Push one T-stop to every e-iris body — the "focus link" analogue and
    /// the loop's starting state. Same encoding as the bench: stop ×10.
    /// Value semantics per 910-0315: display value is the lens T-stop when
    /// the lens reports one, else F-stop — so linked cameras with T-stop
    /// glass genuinely land on the same T. Copy-to-copy variance is exactly
    /// what the match loop then corrects (handoff §7).
    func pushLinkedStop() {
        guard !manualSessionActive else { return }
        guard let x10 = linkStopX10 else { return }
        let targets = nodes.filter { $0.connected && $0.eIris }
        guard !targets.isEmpty else {
            log("iris match: no connected e-iris cameras (run Prepare first — the gate is APERTURE_CONTROL == 1)")
            return
        }
        let skipped = nodes.filter { $0.connected && !$0.eIris }
        if !skipped.isEmpty {
            log("iris match: skipping non-e-iris bodies: \(skipped.map(\.ip).joined(separator: ", "))")
        }
        log("iris match: pushing \(RCP2.stopLabel(x10)) to \(targets.count) camera(s)")
        for node in targets {
            guard let cam = node.camera else { continue }
            Task { _ = await cam.setAperture(x10: x10) }
        }
    }

    // MARK: - Match loop

    var loopRunning: Bool {
        if case .running = loopState { return true }
        return false
    }

    func startMatch() {
        guard loopTask == nil, manualTask == nil, !manualSessionActive else { return }
        matchWorkflow = .electronic
        loopTask = Task { await runMatchLoop() }
    }

    func stopMatch() {
        loopTask?.cancel()
        loopTask = nil
        if loopRunning {
            loopState = .finished("aborted by operator")
            log("match loop: aborted")
        }
    }

    private func participants() -> [CameraNode] {
        nodes.filter { node in
            guard node.connected, node.eIris, node.stream.isStreaming,
                  node.sphere.measurable else {
                if node.match.phase != .excluded {
                    node.match = NodeMatchInfo()
                    node.match.phase = .excluded
                    node.match.note = !node.connected ? "disconnected"
                        : !node.eIris ? "no e-iris"
                        : !node.stream.isStreaming ? "no stream"
                        : "no sphere lock"
                }
                return false
            }
            return true
        }
    }

    private func computeReference(_ parts: [CameraNode]) -> Double? {
        switch referenceMode {
        case .hero:
            guard let sel = selectedNode, parts.contains(where: { $0.id == sel.id }),
                  let ire = sel.sphere.heroIRE else { return nil }
            return ire
        case .median:
            let ires = parts.compactMap { $0.sphere.heroIRE }.sorted()
            guard !ires.isEmpty else { return nil }
            return ires[ires.count / 2]
        case .gray18:
            // Absolute target: 18% gray's expected level for the ACTIVE
            // transform — exact in Log3G10, provisional through IPP2.
            return loopUsesLog3G10 ? Log3G10.grayAnchorIRE : Self.ipp2GrayAnchorIRE
        case .custom:
            return loopCustomTargetIRE
        }
    }

    private enum MatchTransformMode { case log3G10, fallback }

    private func transformPreflight(_ parts: [CameraNode]) async -> MatchTransformMode? {
        var readings: [(CameraNode, MonitorTransformReading)] = []
        for node in parts {
            guard let camera = node.camera else { continue }
            readings.append((node, await camera.readActiveMonitorTransform()))
        }
        guard readings.count == parts.count else {
            loopState = .finished("transform preflight failed: camera actor unavailable")
            log("match loop: transform preflight BLOCKED — a participant has no camera actor")
            return nil
        }

        let logCount = readings.filter { $0.1.state == .log3G10 }.count
        if logCount == readings.count {
            loopUsesLog3G10 = true
            log("match loop: transform preflight PASS — every participant confirms Log3G10")
            return .log3G10
        }
        if logCount > 0 {
            let detail = readings.map { "\($0.0.ip)=\($0.1.state.rawValue)" }.joined(separator: ", ")
            loopState = .finished("transform mismatch: mixed Log3G10 / non-Log3G10 array")
            log("match loop: transform preflight BLOCKED — \(detail)")
            return nil
        }

        let known = readings.compactMap(\.1.presetValue)
        if !known.isEmpty && known.count != readings.count {
            let detail = readings.map { "\($0.0.ip)=\($0.1.presetValue.map(String.init) ?? "unknown")" }.joined(separator: ", ")
            loopState = .finished("transform mismatch: some viewing transforms are unconfirmed")
            log("match loop: transform preflight BLOCKED — \(detail)")
            return nil
        }
        if Set(known).count > 1 {
            let detail = readings.map { "\($0.0.ip)=\($0.1.presetValue.map(String.init) ?? "unknown")" }.joined(separator: ", ")
            loopState = .finished("transform mismatch: monitor presets differ")
            log("match loop: transform preflight BLOCKED — \(detail)")
            return nil
        }

        loopUsesLog3G10 = false
        if known.isEmpty {
            log("match loop: WARNING — transform reads are unavailable on every participant; using bounded sign-only fallback")
        } else {
            log("match loop: all participants share non-Log3G10 preset \(known[0]); using bounded sign-only fallback")
        }
        return .fallback
    }

    private func runMatchLoop() async {
        let parts = participants()
        var didStart = false
        var finalRound = 0
        defer {
            if didStart {
                let spread = currentSpread(parts, log3G10: loopUsesLog3G10)
                soak.recordMatchEvent("match_end", round: finalRound,
                                      finalSpreadIRE: spread.ire,
                                      finalSpreadStops: spread.stops,
                                      detail: matchResultText)
            }
            loopTask = nil
        }

        guard parts.count >= 2 || (parts.count == 1 && referenceMode == .hero) else {
            loopState = .finished("need ≥2 participating cameras (connected + e-iris + streaming + sphere locked)")
            log("match loop: not enough participants")
            return
        }
        guard let transformMode = await transformPreflight(parts) else { return }
        let logMode = transformMode == .log3G10

        for node in parts {
            node.match = NodeMatchInfo()
            node.match.phase = .adjusting
        }
        let toleranceText = logMode
            ? "±\(String(format: "%.3f", toleranceStops)) stops"
            : "±\(String(format: "%.1f", toleranceIRE)) IRE"
        log("match loop: start — \(parts.count) cameras, \(logMode ? "Log3G10 linearized multi-step" : "display sign-only fallback"), tolerance \(toleranceText), budget \(nudgeBudget) steps, reference \(referenceMode.rawValue)")
        soak.recordMatchEvent("match_start", detail: "\(parts.count) cameras; \(logMode ? "log3g10" : "fallback"); tolerance \(toleranceText)")
        didStart = true

        var lastDelta: [UUID: Double] = [:]

        for round in 1...Self.maxRounds {
            if Task.isCancelled { return }
            finalRound = round
            loopState = .running(round: round)
            soak.recordMatchEvent("round", round: round)

            // Fresh measurements: wait for every participant's sphere to be
            // re-measured after this instant (analysis ticks at ~3 Hz).
            let epoch = Date()
            let fresh = await waitFreshMeasurements(parts, after: epoch)
            if !fresh {
                loopState = .finished("stalled: sphere measurements stopped updating")
                log("match loop: measurement stall — check streams / sphere locks")
                return
            }
            guard let ref = computeReference(parts) else {
                loopState = .finished("no reference IRE available")
                return
            }
            referenceIRE = ref

            // Plan this round's corrections.
            var moved: [CameraNode] = []
            var movedOffsets: [UUID: Int] = [:]
            for node in parts {
                guard let ire = node.sphere.heroIRE else { continue }
                let deltaIRE = ire - ref
                let correctionStops = logMode ? Log3G10.stops(between: ref, and: ire) : .nan
                node.match.deltaIRE = deltaIRE
                node.match.deltaStops = correctionStops.isFinite ? correctionStops : nil
                node.match.residualStops = logMode
                    ? (correctionStops.isFinite ? -correctionStops : nil)
                    : (ire > 0 && ref > 0 ? log2(ire / ref) : nil)

                let comparisonDelta = logMode ? correctionStops : deltaIRE
                guard comparisonDelta.isFinite else {
                    node.match.phase = .excluded
                    node.match.note = "invalid Log3G10 linearization"
                    continue
                }
                let withinTolerance = logMode
                    ? abs(correctionStops) <= toleranceStops
                    : abs(deltaIRE) <= toleranceIRE
                if withinTolerance {
                    node.match.phase = .matched
                    node.match.note = logMode ? "within stop tolerance" : "within IRE tolerance"
                    continue
                }
                if node.match.phase == .oscillating { continue }
                let remainingBudget = nudgeBudget - node.match.nudgesUsed
                if remainingBudget <= 0 {
                    node.match.phase = .capped
                    node.match.note = String(format: "DoF budget spent — spill %+.2f stops to exposureAdjust", node.match.residualStops ?? 0)
                    continue
                }
                // Oscillation: sign flipped since last round → the target sits
                // between two list steps. Stop; that's the granularity floor.
                if let prev = lastDelta[node.id], prev.sign != comparisonDelta.sign,
                   abs(prev) > 0, abs(comparisonDelta) > 0 {
                    node.match.phase = .oscillating
                    node.match.note = logMode
                        ? String(format: "straddling target (±%.3f stops) — granularity floor", abs(correctionStops))
                        : String(format: "straddling target (±%.1f IRE) — granularity floor", abs(deltaIRE))
                    log("match loop: [\(node.ip)] oscillating around target — stopping at granularity floor")
                    soak.recordMatchEvent("oscillation", cameraIP: node.ip, round: round,
                                          detail: node.match.note)
                    continue
                }
                lastDelta[node.id] = comparisonDelta

                var offset: Int
                if logMode {
                    // The handoff's computed correction is ref/measured in
                    // scene-linear stops. Positive means "add exposure"; an
                    // ascending aperture list adds darkness, hence the minus.
                    let exposureSteps = min(8, max(-8, Int((correctionStops * 4).rounded())))
                    if exposureSteps == 0 {
                        node.match.phase = .oscillating
                        node.match.note = "correction below one list step — granularity floor"
                        soak.recordMatchEvent("oscillation", cameraIP: node.ip, round: round,
                                              detail: node.match.note)
                        continue
                    }
                    offset = -exposureSteps
                } else {
                    // Too bright → close iris → +1 list step, assuming an
                    // ascending stop list. Runtime direction learning below
                    // preserves the # UNVERIFIED ordering guard.
                    offset = deltaIRE > 0 ? 1 : -1
                }
                if abs(offset) > remainingBudget {
                    offset = offset > 0 ? remainingBudget : -remainingBudget
                }
                if node.match.directionFlipped { offset = -offset }

                node.match.phase = .adjusting
                node.match.nudgesUsed += abs(offset)
                node.match.note = "nudge \(offset > 0 ? "+" : "")\(offset) (\(node.match.nudgesUsed)/\(nudgeBudget))"
                if let cam = node.camera {
                    let ok = await cam.nudgeAperture(offset: offset)
                    if ok {
                        moved.append(node)
                        movedOffsets[node.id] = offset
                        soak.recordMatchEvent("nudge", cameraIP: node.ip, round: round,
                                              nudges: abs(offset), detail: node.match.note)
                    } else {
                        node.match.nudgesUsed = max(0, node.match.nudgesUsed - abs(offset))
                        node.match.note = "nudge rejected / send failed"
                    }
                }
            }

            if moved.isEmpty {
                let allDone = parts.allSatisfy {
                    $0.match.phase == .matched || $0.match.phase == .capped || $0.match.phase == .oscillating
                }
                let matched = parts.filter { $0.match.phase == .matched }.count
                loopState = .finished(allDone
                    ? "converged: \(matched)/\(parts.count) matched in \(round - 1) correction round(s)"
                    : "stopped: no movable cameras")
                log("match loop: done — \(matched)/\(parts.count) within \(toleranceText)")
                logSpillSummary(parts)
                return
            }

            // Wait for every moved iris to settle (pushed cur == target).
            let preIRE = moved.reduce(into: [UUID: Double]()) { $0[$1.id] = $1.sphere.heroIRE }
            let settled = await waitSettle(moved)
            if !settled {
                log("match loop: settle timeout — a set may have been rejected (AE? range limit?) or APERTURE isn't subscribed")
            }

            // Debounce past stream latency before trusting new measurements.
            try? await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
            _ = await waitFreshMeasurements(moved, after: Date().addingTimeInterval(-0.1))

            // Direction sanity: a nudge that moved IRE away from the reference
            // means this body's list order is opposite our assumption.
            for node in moved {
                guard let pre = preIRE[node.id] ?? nil, let post = node.sphere.heroIRE,
                      let delta = node.match.deltaIRE else { continue }
                let wanted: Double = delta > 0 ? -1 : 1
                let got = post - pre
                if abs(got) > 0.5, got.sign != wanted.sign {
                    node.match.directionFlipped.toggle()
                    let learnedSteps = abs(movedOffsets[node.id] ?? 1)
                    node.match.nudgesUsed = max(0, node.match.nudgesUsed - learnedSteps)
                    log("match loop: [\(node.ip)] nudge moved the WRONG way (\(String(format: "%+.1f", got)) IRE) — flipping direction (stop list order # UNVERIFIED)")
                    soak.recordMatchEvent("direction_flip", cameraIP: node.ip, round: round,
                                          directionFlips: 1,
                                          detail: String(format: "IRE moved %+.2f", got))
                }
            }
        }

        loopState = .finished("stopped after \(Self.maxRounds) rounds without full convergence")
        log("match loop: max rounds reached")
        logSpillSummary(parts)
    }

    private var matchResultText: String {
        if case .finished(let text) = loopState { return text }
        return Task.isCancelled ? "cancelled" : "ended"
    }

    private func currentSpread(_ parts: [CameraNode], log3G10: Bool) -> (ire: Double?, stops: Double?) {
        let ires = parts.compactMap { $0.sphere.heroIRE }.sorted()
        guard ires.count >= 2, let lo = ires.first, let hi = ires.last else { return (nil, nil) }
        let stops = log3G10
            ? abs(Log3G10.stops(between: lo, and: hi))
            : (lo > 0 ? log2(hi / lo) : .nan)
        return (hi - lo, stops.isFinite ? stops : nil)
    }

    /// exposureAdjust spill report — the Phase 3 handoff to R3DMatch
    /// (handoff §7: cap iris delta, spill the remainder post-capture).
    private func logSpillSummary(_ parts: [CameraNode]) {
        for node in parts {
            guard let stops = node.match.residualStops, abs(stops) > 0.01 else { continue }
            let qualifier = loopUsesLog3G10 ? "scene-linear Log3G10" : "display-referred estimate"
            log(String(format: "spill: [%@] residual %+.2f stops (%@) → exposureAdjust / R3DMatch", node.ip, stops, qualifier))
        }
    }

    private func waitSettle(_ moved: [CameraNode]) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if moved.allSatisfy({ $0.status.apertureSettled }) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return moved.allSatisfy { $0.status.apertureSettled }
    }

    private func waitFreshMeasurements(_ parts: [CameraNode], after epoch: Date) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.measureTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            let allFresh = parts.allSatisfy { node in
                if let t = node.sphere.measuredAt { return t > epoch }
                return false
            }
            if allFresh { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    // MARK: - Log (same discipline as the bench: the log is a deliverable)

    func log(_ text: String) {
        logLines.append(BenchLogLine(text: text))
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
    }

    func logText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return logLines.map { "\(fmt.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }

    func saveLog() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "r3diris_array_\(stamp).log"
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            try? self.logText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
