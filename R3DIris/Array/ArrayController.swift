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

    // MARK: Discovery (V3's method, ported: TCP subnet sweep on :9998 primary,
    // UDP CAMINFO broadcast fallback — both spend ZERO camera session slots.
    // Manual IP entry remains as the fallback path.)

    @Published var subnet: String = ""         // CIDR / bare / shorthand (Subnet.hosts)
    @Published private(set) var discovering = false
    @Published private(set) var discovered: [DiscoveredCamera] = []

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
        var id: String { rawValue }
    }
    @Published var referenceMode: ReferenceMode = .median
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
        case gray18 = "18% gray · 33.3"
        case custom = "Custom IRE"
        var id: String { rawValue }
    }

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
    private var manualEndRequested = false
    private var manualEndMessage = "Manual Assist aborted by operator."
    private var manualEndWasFailure = false

    static let settleTimeout: TimeInterval = 10
    static let measureTimeout: TimeInterval = 6
    static let maxRounds = 16

    init() {
        soak.onLog = { [weak self] line in self?.log(line) }
        soak.onDurationReached = { [weak self] in
            self?.stopSoak(reason: "duration reached")
        }
    }

    // MARK: - Discovery

    /// PRIMARY: TCP-sweep the subnet on :9998 (V1/V2.1's proven method).
    /// FALLBACK: UDP CAMINFO broadcast when the sweep is empty or no subnet
    /// is set. Already-added bodies are skipped (rule 2 — never touch a live
    /// session).
    func discover() {
        guard !discovering else { return }
        discovering = true
        let cidr = subnet.trimmingCharacters(in: .whitespaces)
        let source = sourceIP.trimmingCharacters(in: .whitespaces)
        let src = source.isEmpty ? nil : source
        let known = Set(nodes.map(\.ip))
        Task {
            var found: [DiscoveredCamera] = []
            if !cidr.isEmpty {
                log("discovery: TCP sweep \(cidr) :9998 (\(Subnet.hosts(from: cidr).count) hosts)")
                found = await TCPScan.discover(cidr: cidr, sourceIP: src, skip: known)
            }
            if found.isEmpty {
                log("discovery: CAMINFO broadcast\(cidr.isEmpty ? " (no subnet set)" : " fallback")")
                let udp = await UDPDiscovery.discover(sourceIP: src)
                found = udp.filter { !known.contains($0.ip) }
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

    // MARK: - Membership

    /// Manual entry — the fallback when discovery can't see the camera
    /// (cross-subnet routes, unusual NIC setups).
    func addCamera() {
        let ip = newIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        newIP = ""
        addNode(ip: ip, label: "")
    }

    private func addNode(ip: String, label: String) {
        guard !nodes.contains(where: { $0.ip == ip }) else { return }
        let node = CameraNode(ip: ip)
        node.onLog = { [weak self] line in self?.log(line) }
        if soak.isRecording { node.attachSoakRecorder(soak) }
        nodes.append(node)
        if selectedNodeID == nil { selectedNodeID = node.id }
        log("added \(ip)\(label.isEmpty ? "" : " (\(label))")")
    }

    func removeCamera(_ node: CameraNode) {
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
        for node in nodes { node.connect(sourceIP: src.isEmpty ? nil : src) }
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
    func setLog3G10OnArray() {
        guard !loopRunning, !manualSessionActive else { return }
        Task {
            let targets = nodes.filter(\.connected)
            guard !targets.isEmpty else {
                log("set Log3G10: no connected cameras")
                return
            }
            log("set Log3G10: starting on \(targets.count) camera(s) — output-side params # UNVERIFIED")
            var confirmed = 0
            for node in targets {
                guard let camera = node.camera else { continue }
                let ok = await camera.setActiveMonitorLog3G10()
                if ok { confirmed += 1 }
                log("set Log3G10: [\(node.ip)] \(ok ? "confirmed" : "FAILED / unconfirmed")")
            }
            log("set Log3G10: complete — \(confirmed)/\(targets.count) confirmed")
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
        manualParticipantIDs.removeAll()
        manualStableSince.removeAll()
        manualArrayStableSince = nil
        manualRecentIRE.removeAll()
        manualLastMeasurementAt.removeAll()
        manualSavedTransforms.removeAll()
        manualChangedOutputs.removeAll()
        for node in nodes { node.manualMatch = ManualMatchInfo() }

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
        manualParticipantCount = parts.count
        if !manualParticipantIDs.contains(selectedNodeID ?? UUID()) {
            selectedNodeID = parts.first?.id
        }
        for node in parts {
            node.manualMatch.phase = .acquiring
            node.manualMatch.detail = "capturing output state"
        }
        log("manual match: preparing \(parts.count) camera(s); APERTURE commands disabled")

        // Capture every current output before changing any of them. Unknown
        // state blocks the transaction so we can always make a safe restore.
        for node in parts {
            guard !manualEndRequested else { await closeManualMatch(); return }
            guard let camera = node.camera else {
                await failManualMatch("Camera actor unavailable for \(node.ip).")
                return
            }
            let reading = await camera.readActiveMonitorTransform()
            guard !reading.parameterID.isEmpty, reading.presetValue != nil else {
                await failManualMatch("Cannot capture the mirrored output preset on \(node.ip); no cameras were intentionally left in an unknown restore state.")
                return
            }
            manualSavedTransforms[node.id] = reading
        }

        manualStatus = "Temporarily setting the mirrored outputs to Log3G10…"
        for node in parts {
            guard !manualEndRequested else { await closeManualMatch(); return }
            guard let camera = node.camera, let saved = manualSavedTransforms[node.id] else {
                await failManualMatch("Output transaction lost \(node.ip).")
                return
            }
            guard saved.presetValue != RCP2.log3G10DisplayPresetValue else { continue }
            // Mark it before the SET: even an unconfirmed SET gets a restore
            // attempt because the camera may have applied it without replying.
            manualChangedOutputs.insert(node.id)
            let ok = await camera.setMonitorDisplayPreset(
                parameterID: saved.parameterID,
                value: RCP2.log3G10DisplayPresetValue,
                reason: "manual match Log3G10")
            guard ok else {
                await failManualMatch("Log3G10 readback failed on \(node.ip).")
                return
            }
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
            target = Log3G10.grayAnchorIRE
        case .custom:
            target = manualCustomTargetIRE ?? 0
        }
        guard target > 0, Log3G10.linearize(target / 100.0) > 0 else {
            await failManualMatch("Captured target is outside the usable Log3G10 range.")
            return
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
            try? await Task.sleep(nanoseconds: 100_000_000)
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

        for node in parts {
            let measurementFresh: Bool
            if let measuredAt = node.sphere.measuredAt {
                measurementFresh = now.timeIntervalSince(measuredAt) <= 1.5
                if measurementFresh, measuredAt != manualLastMeasurementAt[node.id],
                   let ire = node.sphere.heroIRE {
                    var values = manualRecentIRE[node.id, default: []]
                    values.append(ire)
                    if values.count > 5 { values.removeFirst(values.count - 5) }
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
            if await camera.restoreMonitorTransform(saved) {
                restored += 1
            } else {
                failed.append(node.ip)
            }
        }

        let changed = manualChangedOutputs.count
        let restoreText = changed == 0
            ? "Outputs were already Log3G10."
            : "Restored \(restored)/\(changed) changed output preset(s)."
        let failureText = failed.isEmpty ? "" : " Restore requires attention: \(failed.joined(separator: ", "))."
        manualStatus = "\(manualEndMessage) \(restoreText)\(failureText)"
        manualPhase = (manualEndWasFailure || !failed.isEmpty) ? .failed : .finished
        log("manual match: END — \(manualStatus)")
        soak.recordMatchEvent("manual_match_end",
                              finalSpreadStops: manualArraySpreadStops,
                              detail: manualStatus)

        manualSavedTransforms.removeAll()
        manualChangedOutputs.removeAll()
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
