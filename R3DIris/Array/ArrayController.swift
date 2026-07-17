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

    // MARK: Live Sphere Soak

    let soak = SoakRecorder()
    @Published var soakDuration: SoakDurationOption = .thirtyMinutes

    @Published private(set) var logLines: [BenchLogLine] = []

    private var loopTask: Task<Void, Never>?

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
        node.attachSoakRecorder(nil)
        node.disconnect()
        nodes.removeAll { $0.id == node.id }
        if selectedNodeID == node.id { selectedNodeID = nodes.first?.id }
        log("removed \(node.ip)")
    }

    func connectAll() {
        let src = sourceIP.trimmingCharacters(in: .whitespaces)
        for node in nodes { node.connect(sourceIP: src.isEmpty ? nil : src) }
    }

    func disconnectAll() {
        stopMatch()
        if soak.isRecording { stopSoak(reason: "array disconnected") }
        for node in nodes { node.disconnect() }
    }

    func streamAll() {
        for node in nodes where node.connected && !node.stream.isStreaming {
            node.startStream()
        }
    }

    /// Capability gate + APERTURE subscription on every connected body — one
    /// operator action for the whole array, one body at a time (serialized so
    /// a wedge is attributable to a specific camera; rule 11).
    func prepareAll() {
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
        guard !loopRunning else { return }
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
        guard loopTask == nil else { return }
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
