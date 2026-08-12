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
    @Published private(set) var arrayActualQuality: Int? = nil
    @Published private(set) var arrayQualityStatus = "Not verified across participants."
    @Published private(set) var qualityVerificationInProgress = false
    @Published private(set) var qualityControlsLocked = false
    /// Exact camera membership covered by `arrayActualQuality`. Electronic Match
    /// intentionally verifies only participating e-iris bodies, while Manual
    /// Assist verifies every connected body; status from an excluded camera must
    /// not erase proof for a different set.
    private var qualityVerifiedParticipantIDs: Set<UUID> = []

    /// Intersection of runtime factors advertised by every connected body.
    /// Until all bodies have answered `rcp_get_list`, expose the four documented
    /// protocol factors; after a verification pass, the picker reflects only
    /// choices the whole active array says it shares.
    var commonLivestreamQualityOptions: [LivestreamQualityOption] {
        let connected = nodes.filter(\.connected)
        let lists = connected.map(\.status.livestreamQualityOptions).filter { !$0.isEmpty }
        guard !connected.isEmpty, lists.count == connected.count else {
            return (1...4).map {
                .init(value: $0, label: RCP2.livestreamQualityLabels[$0] ?? "\($0)")
            }
        }
        var common = Set(lists[0].map(\.value))
        for list in lists.dropFirst() { common.formIntersection(Set(list.map(\.value))) }
        return common.sorted().map { value in
            let labels = Set(lists.compactMap { list in
                list.first(where: { $0.value == value })?.label
            })
            let label = labels.count == 1
                ? labels.first!
                : (RCP2.livestreamQualityLabels[value] ?? "\(value)")
            return .init(value: value, label: label)
        }
    }

    var subnetHostCount: Int { Subnet.hosts(from: subnet).count }

    // MARK: Iris Match (bulk T-stop push)

    @Published var linkStopText: String = "5.6"

    enum MatchWorkflow: String, CaseIterable, Identifiable {
        case electronic = "Electronic"
        // Hybrid is the operator-in-the-loop session (internally still the
        // `manual*` machinery): it hand-guides manual glass with OPEN/CLOSE and
        // lets the operator push any e-iris participant to the shared target with
        // one command. An all-manual rig behaves exactly like the old Manual
        // Assist; an all-e-iris rig just gets push buttons instead of hand-trims.
        case hybrid = "Hybrid"
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
    /// One fixed production certification hold. Automatic mode advances
    /// immediately after this completes; Operator Proceed keeps focus on the
    /// matched camera until the operator explicitly continues.
    let manualHoldSeconds: Double = 4.0
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
    enum ManualAdvanceMode: String, CaseIterable, Identifiable {
        case automatic = "Automatic"
        case operatorProceed = "Operator Proceed"
        var id: String { rawValue }
    }
    /// Automatic is the existing/default guided behavior. Operator Proceed uses
    /// the same four-second certification gate but never changes cameras until
    /// the operator presses the matched-only Proceed button.
    @Published var manualAdvanceMode: ManualAdvanceMode = .automatic
    /// Cameras that have reached a held match and not since drifted out.
    private var manualCertified: Set<UUID> = []
    /// Final read-only quality proof for the currently focused camera. The
    /// four-second hold cannot certify until a fresh rcp_get returns the same
    /// actual factor captured by array preflight.
    private var manualCertificationQualityApprovedID: UUID?
    private var manualCertificationQualityTask: Task<Void, Never>?
    private var manualCertificationQualityGeneration: UInt64 = 0
    /// True once a session actually reached the Log3G10 transform stage. Lets the
    /// end message distinguish "nothing needed changing" from "blocked before we
    /// touched any output" (which must NOT claim the outputs are in Log3G10).
    private var manualEnteredTransformStage = false

    /// Stable ID-order key for guided advance (GA < GB < …; ip as a fallback).
    private func manualIDKey(_ node: CameraNode) -> String {
        node.status.displayID.isEmpty ? node.ip : node.status.displayID
    }

    private func orderedManualParticipants(_ parts: [CameraNode]) -> [CameraNode] {
        parts.sorted { manualIDKey($0) < manualIDKey($1) }
    }

    /// The next body that has not yet completed its own four-second focused
    /// certification. Wrap so an operator may begin on any camera in the array.
    private func nextUncertifiedManualCamera(
        after current: CameraNode,
        in parts: [CameraNode]
    ) -> CameraNode? {
        let ordered = orderedManualParticipants(parts)
        guard ordered.count > 1,
              let index = ordered.firstIndex(where: { $0.id == current.id }) else {
            return nil
        }
        for offset in 1..<ordered.count {
            let candidate = ordered[(index + offset) % ordered.count]
            if !manualCertified.contains(candidate.id) { return candidate }
        }
        return nil
    }

    /// Move fullscreen focus (and selection) to a camera during the guided flow.
    private func focusManual(on node: CameraNode) {
        guard manualParticipantIDs.contains(node.id) else { return }
        let changed = fullScreenNodeID != node.id
        fullScreenNodeID = node.id
        selectedNodeID = node.id
        if changed {
            log("manual match: focus → \(manualIDKey(node))")
            applyManualStreamSchedule(manualParticipants)
        }
    }

    /// Operator-facing focus request. In Operator Proceed mode the current
    /// camera owns focus until the explicit, quality-reverified Proceed action;
    /// row clicks and generic fullscreen navigation cannot bypass that gate.
    func selectManualCamera(_ node: CameraNode) {
        guard manualPhase == .trimming,
              manualParticipantIDs.contains(node.id) else {
            return
        }
        if manualAdvanceMode == .operatorProceed,
           let currentID = fullScreenNodeID,
           currentID != node.id {
            let currentName = fullScreenNode.map(manualIDKey) ?? "Current camera"
            manualStatus = manualCertified.contains(currentID)
                ? "\(currentName) is certified — use Proceed for the verified handoff."
                : "\(currentName) must complete its focused match before proceeding."
            return
        }
        focusManual(on: node)
    }

    // MARK: - Hybrid e-iris push (operator-approved)

    /// List-step offset that moves this camera's iris toward the captured target,
    /// in the SAME quarter-stop convention the Electronic loop uses — so a hand on
    /// the ring and a pushed motor behave identically. nil when there is nothing
    /// worth sending: no live correction, already inside tolerance, or the move
    /// rounds below one list step (the granularity floor).
    private func hybridApertureOffset(for node: CameraNode) -> Int? {
        guard let correction = node.manualMatch.correctionStops, correction.isFinite,
              abs(correction) > manualToleranceStops else { return nil }
        let steps = min(8, max(-8, Int((correction * 4).rounded())))
        guard steps != 0 else { return nil }
        return -steps
    }

    /// Whether the operator can push this camera to the shared target right now:
    /// an active Hybrid session in trimming/complete, a connected e-iris
    /// participant with an actor, and a non-trivial correction pending.
    func canPushHybrid(_ node: CameraNode) -> Bool {
        manualSessionActive
            && (manualPhase == .trimming || manualPhase == .complete)
            && manualParticipantIDs.contains(node.id)
            && node.connected && node.eIris && node.camera != nil
            && hybridApertureOffset(for: node) != nil
    }

    /// Count of e-iris participants the operator could push right now — drives the
    /// array-wide button's enable state and label.
    var hybridPushableCount: Int {
        manualParticipants.filter { canPushHybrid($0) }.count
    }

    /// Push one e-iris participant one planned step toward the target. Operator-
    /// approved: nothing here runs on a timer. Re-press after the reading settles
    /// to converge — the same feedback loop as a hand on a manual ring, and it
    /// never touches manual glass.
    func pushHybridAperture(_ node: CameraNode) {
        guard canPushHybrid(node), let offset = hybridApertureOffset(for: node),
              let cam = node.camera else { return }
        log("hybrid: push \(manualIDKey(node)) APERTURE \(offset > 0 ? "+" : "")\(offset) step(s) toward \(manualTargetIRE.map { String(format: "%.0f IRE", $0) } ?? "target")")
        soak.recordMatchEvent("hybrid_push", cameraIP: node.ip,
                              detail: "offset \(offset); correction \(node.manualMatch.correctionStops.map { String(format: "%+.2fst", $0) } ?? "n/a")")
        Task { _ = await cam.nudgeAperture(offset: offset) }
    }

    /// Array-wide convenience: push every e-iris participant currently out of
    /// tolerance one step toward the target. Manual glass is never touched.
    func pushAllHybridApertures() {
        let targets = manualParticipants.filter { canPushHybrid($0) }
        guard !targets.isEmpty else {
            log("hybrid: no e-iris participants need a push")
            return
        }
        log("hybrid: pushing \(targets.count) e-iris body(ies) toward target")
        for node in targets { pushHybridAperture(node) }
    }

    /// Accept every connected camera's current auto-detected lock as a durable
    /// operator seed. This is the "don't lose the solve" action: run it before
    /// leaving Electronic (or any time), and the locks survive a workflow switch
    /// and the Log3G10 swap instead of coasting out as fragile auto-locks. A
    /// camera that already carries an operator seed is left untouched.
    func seedAllSolved() {
        var newlySeeded = 0, alreadyDurable = 0, noLock = 0
        for node in nodes where node.connected {
            if node.sphere.seeded { alreadyDurable += 1; continue }
            if node.acceptCurrentMask() != nil { newlySeeded += 1 } else { noLock += 1 }
        }
        log("seed all solved: \(newlySeeded) newly seeded, \(alreadyDurable) already durable, \(noLock) with no lock to seed")
    }

    // MARK: - Electronic manual override (post-match trim)

    /// Whether the operator can apply a manual iris override to this camera right
    /// now: the Electronic workflow, the loop idle, and a connected e-iris body
    /// with an actor. Gating to loop-idle means an override can never fight an
    /// in-flight convergence — it is the deliberate move you make AFTER the
    /// automated match has landed.
    func canOverride(_ node: CameraNode) -> Bool {
        matchWorkflow == .electronic
            && !loopRunning
            && !manualSessionActive
            && node.connected && node.eIris && node.camera != nil
    }

    /// Manually nudge one e-iris camera a single list step off its matched
    /// position. `open == true` adds exposure (opens the iris); false removes it
    /// (closes). The camera is flagged as a manual override so the UI shows it is
    /// deliberately off the computed match — the loop never auto-undoes it; only
    /// re-running the match (which resets NodeMatchInfo) clears it.
    func overrideNudge(_ node: CameraNode, open: Bool) {
        guard canOverride(node), let cam = node.camera else { return }
        // An ascending aperture list darkens as it climbs, so opening (more
        // exposure) steps DOWN the list — the same sign the loop and Hybrid use.
        let offset = open ? -1 : 1
        node.match.manualOverride = true
        node.match.overrideSteps += offset
        node.match.note = overrideNote(node.match.overrideSteps)
        log("override: \(manualIDKey(node)) manual \(open ? "OPEN" : "CLOSE") 1 step (net \(node.match.overrideSteps > 0 ? "+" : "")\(node.match.overrideSteps)) — off computed match, will not auto-undo")
        soak.recordMatchEvent("manual_override", cameraIP: node.ip,
                              detail: "\(open ? "open" : "close") 1 step; net \(node.match.overrideSteps)")
        Task { _ = await cam.nudgeAperture(offset: offset) }
    }

    /// Array-wide manual override — nudge every connected e-iris camera one step
    /// the same direction (e.g. a DP wants the whole array a hair warmer). Because
    /// every camera moves equally, a relative-reference match stays matched to
    /// itself; an absolute-target match is deliberately biased until re-run.
    func overrideNudgeAll(open: Bool) {
        let targets = nodes.filter { canOverride($0) }
        guard !targets.isEmpty else {
            log("override: no e-iris cameras available to nudge")
            return
        }
        log("override: array-wide manual \(open ? "OPEN" : "CLOSE") 1 step on \(targets.count) e-iris camera(s)")
        for node in targets { overrideNudge(node, open: open) }
    }

    private func overrideNote(_ steps: Int) -> String {
        if steps == 0 { return "manual override (returned to match)" }
        let dir = steps < 0 ? "open" : "close"
        return "manual override \(dir) \(abs(steps)) step\(abs(steps) == 1 ? "" : "s")"
    }

    private var manualEndRequested = false
    private var manualEndMessage = "Manual Assist aborted by operator."
    private var manualEndWasFailure = false
    /// Immutable actual quality captured by the Manual Assist preflight. This
    /// remains available long enough to fail closed even after the UI's aggregate
    /// proof is invalidated by a reconnect or missing read-back.
    private var manualExpectedQuality: Int?

    static let settleTimeout: TimeInterval = 10
    static let measureTimeout: TimeInterval = 6
    static let maxRounds = 16
    /// How long the one-camera Capture + Start queue waits for a locally-woken
    /// participant to prove its transport and native ROI measurement path.
    static let manualReadyGrace: TimeInterval = 12
    /// Capture + Start is expected immediately after sphere solving. Require a
    /// recent native reading from every trusted lock before parking the array so
    /// an old candidate/ROI cannot be frozen and sampled as if it were current.
    static let manualSolveFreshness: TimeInterval = 5
    /// Once a camera has changed transform, keep its one live feed visible long
    /// enough for the operator to see the Log3G10 result before the queue parks
    /// it and advances. This is a presentation floor, not a measurement delay.
    static let manualVisualVerificationSeconds: TimeInterval = 0.75
    /// DISPLAY_PRESET is value-with-target: SET confirmation can precede CUR by
    /// several video frames. Discard this post-SET interval before establishing
    /// the baseline epoch so transitional frames cannot contaminate the median.
    static let manualTransformSettleSeconds: TimeInterval = 0.75

    // MARK: - Stream auto-recovery
    /// Automatically restart a participant's livestream if it drops or stalls.
    /// Long matches outlive the MJPEG feed (idle timeout / transient network), and
    /// a 36-camera calibration must not depend on someone noticing a dead tile.
    @Published var autoRecoverStreams = true
    private var streamRetryCount: [UUID: Int] = [:]
    private var streamLastRetryAt: [UUID: Date] = [:]
    private var watchdogTask: Task<Void, Never>?
    /// Normal preview/solve feeds get a conservative transport timeout. Focused
    /// Manual Assist feedback fails into HOLD much sooner.
    private static let streamStallTimeout: TimeInterval = 8.0
    private static let focusedStreamStallTimeout: TimeInterval = 1.5
    private static let warmStreamStallTimeout: TimeInterval = 3.0
    /// Focused hold progress is measurement-driven. If native ROI samples pause
    /// longer than this, stale wall-clock time cannot accrue toward certification.
    private static let focusedMeasurementContinuity: TimeInterval = 0.5
    /// Normal preview/solve feeds receive a long post-start grace so camera
    /// enable and first-frame settle cannot look like a stall. Focused and warm
    /// roles use their shorter role timeout because they are already HTTP-only
    /// wakes inside a measurement-critical session.
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

    /// Recover local HTTP readers only. Pixel sameness is deliberately excluded:
    /// a solved sphere is expected to remain still. Parked readers are intentional
    /// and therefore invisible to the watchdog. Retry timing is bounded and
    /// role-aware so a focused camera receives urgent service without a 40-camera
    /// recovery wave.
    func recoverDeadStreams() {
        guard autoRecoverStreams else { return }
        let now = Date()
        for node in nodes where node.connected
            && node.streamingDesired
            && node.streamRole != .parked {
            // Still inside the post-(re)start settle window — leave it alone.
            let startGrace: TimeInterval
            switch node.streamRole {
            case .focused: startGrace = Self.focusedStreamStallTimeout
            case .warm: startGrace = Self.warmStreamStallTimeout
            case .normal: startGrace = Self.streamStartGrace
            case .parked: continue
            }
            if let started = node.lastStreamStartAt,
               !node.streamRecovering,
               now.timeIntervalSince(started) < startGrace { continue }

            let last = node.stream.stats.lastFrameAt
            let timeout: TimeInterval
            switch node.streamRole {
            case .focused: timeout = Self.focusedStreamStallTimeout
            case .warm: timeout = Self.warmStreamStallTimeout
            case .normal: timeout = Self.streamStallTimeout
            case .parked: continue
            }
            let dead = !node.stream.isStreaming
                || last.map { now.timeIntervalSince($0) > timeout } ?? true

            if dead {
                requestStreamRecovery(node, now: now)
            } else if streamRetryCount[node.id] != nil || node.streamRecovering {
                streamRetryCount[node.id] = nil
                streamLastRetryAt[node.id] = nil
            }
        }
    }

    /// Single recovery gate shared by the 0.5 Hz watchdog and the 20 Hz focused
    /// guidance loop. The first HTTP-only reopen is immediate; subsequent attempts
    /// back off. No attempt writes camera quality or livestream enable.
    private func requestStreamRecovery(_ node: CameraNode, now: Date = Date()) {
        guard autoRecoverStreams, node.connected, node.streamingDesired,
              node.streamRole != .parked else { return }
        let attempt = (streamRetryCount[node.id] ?? 0) + 1
        let delays: [TimeInterval]
        switch node.streamRole {
        case .focused: delays = [0, 3, 5, 8, 15, 30]
        case .warm: delays = [0, 3, 8, 15, 30]
        case .normal: delays = [0, 5, 10, 20, 30]
        case .parked: return
        }
        let delay = delays[min(attempt - 1, delays.count - 1)]
        if let lastAttempt = streamLastRetryAt[node.id],
           now.timeIntervalSince(lastAttempt) < delay { return }
        streamRetryCount[node.id] = attempt
        streamLastRetryAt[node.id] = now
        let age = node.stream.stats.lastFrameAt.map {
            String(format: "%.1fs without a JPEG", now.timeIntervalSince($0))
        } ?? "no JPEG received"
        node.reopenLocalStream(reason: age, attempt: attempt)
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

    /// Push one exact RCP2 quality factor to every connected body, then compare
    /// the independent actual read-backs. A requested value is never treated as
    /// measurement truth.
    func setQualityAll() {
        guard !qualityControlsLocked, !manualSessionActive, !qualityVerificationInProgress else {
            log("array quality: change BLOCKED while a measurement workflow owns the quality lock")
            return
        }
        let q = arrayQuality
        let targets = nodes.filter(\.connected)
        guard !targets.isEmpty else {
            arrayQualityStatus = "No connected cameras to verify."
            return
        }
        qualityVerificationInProgress = true
        Task {
            _ = await verifyUniformLivestreamQuality(targets, requested: q,
                                                     context: "operator apply")
            qualityVerificationInProgress = false
        }
    }

    /// Set + read back quality on every camera actor. Measurement may begin only
    /// if every participant returns a value
    /// and those ACTUAL values are identical. If every camera clamps to the same
    /// value, adopt that value as the array setting and remember it for restarts.
    private func verifyUniformLivestreamQuality(_ parts: [CameraNode],
                                                requested: Int,
                                                context: String) async -> Bool {
        guard !parts.isEmpty else { return false }
        arrayActualQuality = nil
        qualityVerifiedParticipantIDs.removeAll()
        arrayQualityStatus = "Reading camera quality factors…"
        log("array quality: \(context) — request \(RCP2.livestreamQualityLabels[requested] ?? "\(requested)") on \(parts.count) participant(s), then compare actual read-back")

        var cameras: [(UUID, CameraActor)] = []
        for node in parts {
            guard let camera = node.camera else {
                arrayQualityStatus = "Blocked: \(node.displayName) has no camera session."
                log("array quality: BLOCKED — \(node.ip) has no CameraActor")
                return false
            }
            cameras.append((node.id, camera))
        }

        // Each body owns an independent actor/session whose request transactions
        // remain serialized internally. Verify bodies concurrently so an array
        // preflight costs one RCP timeout window, not N timeout windows.
        var byID: [UUID: LivestreamQualityVerification] = [:]
        await withTaskGroup(of: (UUID, LivestreamQualityVerification).self) { group in
            for (id, camera) in cameras {
                group.addTask {
                    (id, await camera.setLivestreamQuality(requested))
                }
            }
            for await (id, verification) in group {
                byID[id] = verification
            }
        }
        let readings = parts.compactMap { node in byID[node.id].map { (node, $0) } }

        let missing = readings.filter { $0.1.actual == nil }.map { $0.0.displayName }
        guard missing.isEmpty else {
            arrayQualityStatus = "Blocked: no actual quality read-back from \(missing.joined(separator: ", "))."
            log("array quality: BLOCKED — missing actual read-back: \(missing.joined(separator: ", "))")
            return false
        }

        let actualValues = Set(readings.compactMap { $0.1.actual })
        guard actualValues.count == 1, let actual = actualValues.first else {
            let detail = readings.map {
                "\($0.0.displayName)=\($0.1.actual.flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO REPLY")"
            }.joined(separator: ", ")
            arrayQualityStatus = "Blocked: participant read-backs differ (\(detail))."
            log("array quality: MISMATCH / measurement BLOCKED — \(detail)")
            return false
        }

        arrayActualQuality = actual
        qualityVerifiedParticipantIDs = Set(parts.map(\.id))
        arrayQuality = actual
        for (node, _) in readings { node.desiredQuality = actual }
        let label = RCP2.livestreamQualityLabels[actual] ?? "\(actual)"
        let clamp = actual == requested ? "" : " (camera-selected; requested \(RCP2.livestreamQualityLabels[requested] ?? "\(requested)"))"
        arrayQualityStatus = "Locked \(label) across \(parts.count) actual read-backs\(clamp)."
        log("array quality: PASS — every participant actual read-back \(label)\(clamp)")
        return true
    }

    /// Capture + Start follows sphere solving within seconds. The camera factors
    /// are already configured, so this preflight is read-only: query each body's
    /// runtime list/current value and compare them without rewriting quality or
    /// restarting any HTTP reader.
    private func verifyExistingUniformLivestreamQuality(
        _ parts: [CameraNode],
        context: String
    ) async -> Bool {
        guard !parts.isEmpty else { return false }
        arrayActualQuality = nil
        qualityVerifiedParticipantIDs.removeAll()
        arrayQualityStatus = "Reading existing camera quality factors…"
        log("array quality: \(context) — read-only actual comparison on \(parts.count) participant(s)")

        var cameras: [(UUID, CameraActor)] = []
        for node in parts {
            guard let camera = node.camera else {
                arrayQualityStatus = "Blocked: \(node.displayName) has no camera session."
                return false
            }
            cameras.append((node.id, camera))
        }

        var byID: [UUID: LivestreamQualityVerification] = [:]
        await withTaskGroup(of: (UUID, LivestreamQualityVerification).self) { group in
            for (id, camera) in cameras {
                group.addTask {
                    let options = await camera.getLivestreamQualityOptions()
                    let actual = await camera.readLivestreamQuality()
                    return (
                        id,
                        LivestreamQualityVerification(
                            requested: actual ?? -1,
                            actual: actual,
                            options: options
                        )
                    )
                }
            }
            for await (id, result) in group { byID[id] = result }
        }

        let readings = parts.compactMap { node in byID[node.id].map { (node, $0) } }
        let missing = readings.filter { $0.1.actual == nil }.map { $0.0.displayName }
        guard readings.count == parts.count, missing.isEmpty else {
            arrayQualityStatus = "Blocked: no actual quality read-back from \(missing.joined(separator: ", "))."
            log("array quality: BLOCKED — read-only actual missing: \(missing.joined(separator: ", "))")
            return false
        }
        let actualValues = Set(readings.compactMap { $0.1.actual })
        guard actualValues.count == 1, let actual = actualValues.first else {
            let detail = readings.map {
                "\($0.0.displayName)=\($0.1.actual.flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO REPLY")"
            }.joined(separator: ", ")
            arrayQualityStatus = "Blocked: participant read-backs differ (\(detail))."
            log("array quality: MISMATCH / measurement BLOCKED — \(detail)")
            return false
        }

        arrayActualQuality = actual
        qualityVerifiedParticipantIDs = Set(parts.map(\.id))
        arrayQuality = actual
        for (node, _) in readings { node.desiredQuality = actual }
        let label = RCP2.livestreamQualityLabels[actual] ?? "\(actual)"
        arrayQualityStatus = "Locked \(label) across \(parts.count) existing actual read-backs."
        log("array quality: PASS — existing actual read-back \(label) on every participant")
        return true
    }

    /// A verified array value is evidence about the cameras' *current* actual
    /// read-backs, not a sticky preference. Reconnects clear CameraActor state,
    /// and an external quality change can arrive at any time, so invalidate the
    /// array proof as soon as any participant no longer reports the value that
    /// was verified.
    private func participantStatusDidChange(_ node: CameraNode) {
        guard qualityVerifiedParticipantIDs.contains(node.id) else { return }
        guard let verified = arrayActualQuality else { return }
        guard node.connected, node.status.livestreamQuality == verified else {
            arrayActualQuality = nil
            qualityVerifiedParticipantIDs.removeAll()
            if node.connected {
                arrayQualityStatus =
                    "Actual quality proof lost on \(node.displayName); re-verify before measurement."
            } else {
                arrayQualityStatus =
                    "\(node.displayName) disconnected; actual quality must be re-verified."
            }
            return
        }
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
        let candidates = manualSessionActive ? manualParticipants : nodes
        guard let current = fullScreenNodeID, !candidates.isEmpty else { return }
        let ordered = candidates.sorted { manualIDKey($0) < manualIDKey($1) }
        guard let idx = ordered.firstIndex(where: { $0.id == current }) else { return }
        let next = ordered[(idx + delta + ordered.count) % ordered.count]
        if manualSessionActive {
            selectManualCamera(next)
        } else {
            fullScreenNodeID = next.id
            selectedNodeID = next.id
        }
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
        node.onStatusChange = { [weak self] node in
            self?.participantStatusDidChange(node)
        }
        node.diagnosticsEnabled = logSphereDiagnostics
        node.desiredQuality = arrayQuality
        node.stream.dropToLatestFrame = dropStaleFrames
        if soak.isRecording { node.attachSoakRecorder(soak) }
        nodes.append(node)
        arrayActualQuality = nil
        qualityVerifiedParticipantIDs.removeAll()
        arrayQualityStatus = "Array changed; actual quality must be re-verified."
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
        guard !manualSessionActive, !manualRestorePending else {
            log("remove camera: blocked while Manual Assist owns reversible output state — Finish or Abort first")
            return
        }
        node.attachSoakRecorder(nil)
        node.disconnect()
        nodes.removeAll { $0.id == node.id }
        arrayActualQuality = nil
        qualityVerifiedParticipantIDs.removeAll()
        arrayQualityStatus = "Array changed; actual quality must be re-verified."
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
            if node.connected {
                node.refresh()
                revived += 1
            } else if node.camera == nil {
                node.connect(sourceIP: s)
                connecting += 1
            } else {
                // A CameraActor can exist while its RCP link is parked/down.
                // `connect()` intentionally no-ops in that state; revive the
                // existing actor so a pending output restore can be retried.
                node.refresh()
                connecting += 1
            }
        }
        log("connect all: \(connecting) connecting, \(revived) already up (revived)")
    }

    func disconnectAll() {
        guard !manualSessionActive, !manualRestorePending else {
            log("disconnect all: blocked while Manual Assist owns reversible output state — Finish or Abort first")
            return
        }
        stopMatch()
        if soak.isRecording { stopSoak(reason: "array disconnected") }
        for node in nodes { node.disconnect() }
        arrayActualQuality = nil
        qualityVerifiedParticipantIDs.removeAll()
        arrayQualityStatus = "Disconnected; actual quality is not verified."
    }

    func streamAll() {
        guard !manualSessionActive else { return }
        for node in nodes where node.connected && !node.stream.isStreaming {
            if node.streamingDesired {
                if node.streamRole == .parked {
                    // A completed Manual Assist session intentionally leaves
                    // local readers parked. Stream All revives those readers
                    // without rewriting camera enable or quality.
                    node.setStreamRole(.normal)
                } else {
                    node.reopenLocalStream(reason: "operator Stream All", attempt: 1)
                }
            } else {
                node.startStream()
            }
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
            // During Manual Assist, do not let a global recovery action expand
            // the scheduler's reader budget. Outsiders are left untouched;
            // parked participants may have their RCP actor revived but only the
            // focused/warm roles are eligible for an HTTP-only reopen.
            if manualSessionActive, !manualParticipantIDs.contains(node.id) {
                continue
            }
            let manualHTTPRoleIsActive =
                node.streamRole == .focused || node.streamRole == .warm
            let mayOpenLocalReader = !manualSessionActive
                || (manualHTTPRoleIsActive && node.streamingDesired)

            if !node.connected {
                // Session fully dropped (camera == nil) — rebuild it. Its seed is
                // already gone in this case and will need re-placing.
                if node.camera == nil {
                    node.connect(sourceIP: s)
                } else {
                    node.refresh()
                }
                // An intentionally parked participant stays parked. A focused
                // or warm participant reopens only its local HTTP reader.
                if node.streamRole != .parked, mayOpenLocalReader {
                    if node.streamingDesired {
                        node.reopenLocalStream(reason: "operator reconnect", attempt: 1)
                    } else {
                        node.startStream()
                    }
                }
                reconnected += 1
            } else if !node.stream.isStreaming,
                      node.streamRole != .parked,
                      mayOpenLocalReader {
                node.refresh()        // revive the RCP session
                if node.streamingDesired {
                    node.reopenLocalStream(reason: "operator reconnect", attempt: 1)
                } else {
                    node.startStream()
                }
                restreamed += 1
            }
        }
        log("reconnect: \(reconnected) session(s) revived, \(restreamed) active local reader(s) reopened; parked readers left idle")
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
        guard !loopRunning, !manualSessionActive, !manualRestorePending else { return }
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
        guard !loopRunning, !manualSessionActive, !manualRestorePending,
              !savedLoopTransforms.isEmpty else { return }
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

    /// A failed output restore remains owned reversible state even though the
    /// measurement task has ended. It must block new workflows until retried.
    var manualRestorePending: Bool { !manualChangedOutputs.isEmpty }
    var manualChangedOutputCount: Int { manualChangedOutputs.count }

    var workflowBusy: Bool {
        loopRunning || manualSessionActive || manualRestorePending
    }

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
        guard manualTask == nil, !loopRunning, !manualSessionActive,
              !manualRestorePending, !qualityControlsLocked,
              !qualityVerificationInProgress else { return }
        guard manualTransform.isLog3G10 else {
            manualPhase = .failed
            manualStatus =
                "Display (IPP2) stop guidance is not calibrated. Select Log3G10 for an exposure-accurate Manual Assist session."
            return
        }
        guard manualTargetMode != .custom || manualCustomTargetIRE != nil else {
            manualPhase = .failed
            manualStatus = "Custom target must be a valid Log3G10 IRE between 0 and 100."
            return
        }

        matchWorkflow = .hybrid
        manualEndRequested = false
        manualEndWasFailure = false
        manualEndMessage = "Hybrid session aborted by operator."
        manualExpectedQuality = nil
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
        manualFrozenNodes.removeAll()
        manualCertified.removeAll()
        invalidateManualCertificationQualityProof()
        manualEnteredTransformStage = false
        fullScreenNodeID = nil
        for node in nodes { node.manualMatch = ManualMatchInfo() }

        manualPhase = .preparing
        manualStatus = "Checking streams, sphere locks, and mirrored outputs…"
        qualityControlsLocked = true
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

    /// Retry only the exact output restores that previously failed. Saved
    /// preset values remain in memory until every changed camera confirms its
    /// restore, so a transient RCP loss cannot silently strand Log3G10.
    func retryManualRestore() {
        guard manualTask == nil, manualRestorePending,
              !manualSessionActive else { return }
        manualEndWasFailure = false
        manualEndMessage = "Manual Assist restore retry complete."
        manualEndRequested = true
        manualPhase = .restoring
        manualStatus = "Retrying saved output presets…"
        qualityControlsLocked = true
        log("manual match: retrying \(manualChangedOutputs.count) outstanding output restore(s)")
        manualTask = Task { await closeManualMatch() }
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
        guard !manualEndRequested else {
            await closeManualMatch()
            return
        }
        // Disconnected nodes are outside the active array. Sphere solving has
        // just completed, so each connected participant must retain a solved ROI
        // and an enabled livestream intent, but Capture + Start deliberately does
        // NOT keep every HTTP reader live. It parks them, then wakes one camera at
        // a time for transform verification and baseline capture.
        let parts = nodes.filter(\.connected)
        guard parts.count >= 2 else {
            await failManualMatch("Need at least two connected cameras for Manual Assist.")
            return
        }
        let unsolved = parts.filter {
            !$0.sphere.measurable || !$0.streamingDesired
        }
        guard unsolved.isEmpty else {
            await failManualMatch(
                "Lock a measurable sphere and start its stream before Capture + Start on: " +
                    unsolved.map(\.displayName).joined(separator: ", ")
            )
            return
        }
        let freshnessEpoch = Date()
        let staleSolve = parts.filter { node in
            guard let measuredAt = node.sphere.measuredAt else { return true }
            return freshnessEpoch.timeIntervalSince(measuredAt)
                > Self.manualSolveFreshness
        }
        guard staleSolve.isEmpty else {
            await failManualMatch(
                "Sphere solve is no longer fresh on: "
                    + staleSolve.map(\.displayName).joined(separator: ", ")
                    + ". Wake/re-solve those cameras, then Capture + Start."
            )
            return
        }

        manualParticipantIDs = Set(parts.map(\.id))
        manualParticipantCount = parts.count
        let ordered = orderedManualParticipants(parts)
        selectedNodeID = ordered.first?.id
        for node in parts {
            node.manualMatch.phase = .acquiring
            node.manualMatch.detail = "queued for transform + baseline capture"
        }
        log("manual match: preparing \(parts.count) camera(s) through one local MJPEG reader; APERTURE commands disabled")

        // Shed the N-camera decode/network workload immediately when Capture +
        // Start is pressed. Sphere solving just finished, so the solved ROIs and
        // RCP sessions are fresh; parking touches neither of them.
        let parkEpoch = Date()
        for node in nodes where node.streamingDesired || node.stream.isStreaming {
            transitionManualStreamRole(node, to: .parked, now: parkEpoch)
        }

        let qualityVerified = await verifyExistingUniformLivestreamQuality(
            parts,
            context: "Manual Assist preflight"
        )
        guard !manualEndRequested else {
            await closeManualMatch()
            return
        }
        guard qualityVerified else {
            await failManualMatch("Livestream quality verification failed. Every participant must return the same actual quality before capture. \(arrayQualityStatus)")
            return
        }
        guard let verifiedQuality = arrayActualQuality else {
            await failManualMatch("Livestream quality proof disappeared after preflight.")
            return
        }
        manualExpectedQuality = verifiedQuality

        // Freeze every solved ROI before any transform swap or local HTTP wake.
        // The sphere and camera should not move between solving and Capture +
        // Start; the wake gate below nevertheless requires fresh native samples.
        if manualTransform.isLog3G10 {
            for node in parts where node.freezeTransformLock() {
                manualFrozenNodes.insert(node.id)
            }
            if !manualFrozenNodes.isEmpty {
                log("manual match: froze \(manualFrozenNodes.count) auto-locked mask(s) to hold through the Log3G10 swap")
            }
        } else {
            log("manual match: Display (IPP2) — outputs untouched, 18% gray anchored at \(String(format: "%.1f", Self.ipp2GrayAnchorIRE)) IRE")
        }

        var baselines: [UUID: Double] = [:]
        for (index, node) in ordered.enumerated() {
            guard !manualEndRequested else { await closeManualMatch(); return }
            if let qualityFailure = manualQualityInvariantFailure(
                parts,
                expected: verifiedQuality
            ) {
                await failManualMatch("Measurement stopped: \(qualityFailure)")
                return
            }
            selectedNodeID = node.id
            fullScreenNodeID = node.id
            manualStatus =
                "\(node.displayName): waking stream \(index + 1)/\(ordered.count)…"
            let wakeEpoch = Date()
            transitionManualStreamRole(node, to: .focused, now: wakeEpoch)
            guard await waitForManualCameraReady(node, after: wakeEpoch) else {
                if manualEndRequested {
                    await closeManualMatch()
                } else {
                    await failManualMatch(
                        "\(node.displayName) did not deliver three fresh native sphere measurements."
                    )
                }
                return
            }

            guard let camera = node.camera else {
                await failManualMatch("Camera actor unavailable for \(node.ip).")
                return
            }
            manualStatus =
                "\(node.displayName): verifying actual stream quality \(index + 1)/\(ordered.count)…"
            let focusedQuality = await camera.readLivestreamQuality()
            guard !manualEndRequested else {
                await closeManualMatch()
                return
            }
            guard focusedQuality == verifiedQuality else {
                let actual = focusedQuality
                    .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
                await failManualMatch(
                    "\(node.displayName) returned \(actual) while focused; expected \(RCP2.livestreamQualityLabels[verifiedQuality] ?? "\(verifiedQuality)")."
                )
                return
            }

            let visualVerificationStarted = Date()
            var baselineEpoch = Date()
            if manualTransform.isLog3G10 {
                manualStatus =
                    "\(node.displayName): setting and visually verifying Log3G10 \(index + 1)/\(ordered.count)…"
                let reading = await camera.readActiveMonitorTransform()
                guard !manualEndRequested else {
                    await closeManualMatch()
                    return
                }
                guard !reading.parameterID.isEmpty, let before = reading.presetValue else {
                    await failManualMatch(
                        "Cannot resolve/read the Look on \(node.ip)'s livestream mirror output."
                    )
                    return
                }
                manualSavedTransforms[node.id] = reading
                if before != RCP2.log3G10DisplayPresetValue {
                    manualChangedOutputs.insert(node.id)
                    let ok = await camera.setMonitorDisplayPreset(
                        parameterID: reading.parameterID,
                        value: RCP2.log3G10DisplayPresetValue,
                        reason: "manual match Log3G10"
                    )
                    guard !manualEndRequested else {
                        await closeManualMatch()
                        return
                    }
                    guard ok else {
                        await failManualMatch(
                            "Could not set Log3G10 on \(node.ip) (\(reading.parameterID))."
                        )
                        return
                    }
                    try? await Task.sleep(
                        nanoseconds: UInt64(
                            Self.manualTransformSettleSeconds * 1_000_000_000
                        )
                    )
                    guard !manualEndRequested else {
                        await closeManualMatch()
                        return
                    }
                }
                // Whether newly changed or already Log3G10, only measurements
                // after all transform reads/settling may enter this baseline.
                baselineEpoch = Date()
            }

            manualStatus =
                "\(node.displayName): capturing post-transform baseline \(index + 1)/\(ordered.count)…"
            guard let samples = await collectManualSamples(
                node,
                after: baselineEpoch,
                count: 3,
                timeout: Self.manualReadyGrace
            ),
                  let baseline = median(samples) else {
                if manualEndRequested {
                    await closeManualMatch()
                } else {
                    await failManualMatch(
                        "Could not capture a fresh locked-sphere baseline on \(node.displayName)."
                    )
                }
                return
            }
            if let qualityFailure = manualQualityInvariantFailure(
                parts,
                expected: verifiedQuality
            ) {
                await failManualMatch("Measurement stopped: \(qualityFailure)")
                return
            }
            baselines[node.id] = baseline
            manualRecentIRE[node.id] = Array(samples.suffix(3))
            manualLastMeasurementAt[node.id] = node.sphere.measuredAt
            node.manualMatch.baselineIRE = baseline
            node.manualMatch.currentIRE = baseline
            node.manualMatch.detail = "post-transform baseline captured"
            let visibleFor = Date().timeIntervalSince(visualVerificationStarted)
            if visibleFor < Self.manualVisualVerificationSeconds {
                let remaining = Self.manualVisualVerificationSeconds - visibleFor
                try? await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000)
                )
            }
            // The tile retains this fresh post-transform frame for visual review.
            transitionManualStreamRole(node, to: .parked, now: Date())
        }
        guard !manualEndRequested else { await closeManualMatch(); return }
        // Every participant's mirrored output was successfully read and
        // verified at this point. Only now is it safe for closeManualMatch() to
        // report "already Log3G10" when no camera actually required a SET.
        manualEnteredTransformStage = manualTransform.isLog3G10

        let rawTarget: Double
        switch manualTargetMode {
        case .median:
            rawTarget = median(Array(baselines.values)) ?? 0
        case .gray18:
            // 18% gray anchors at 33.3 IRE in Log3G10, 42.3 IRE in IPP2.
            rawTarget = manualTransform.isLog3G10 ? Log3G10.grayAnchorIRE : Self.ipp2GrayAnchorIRE
        case .custom:
            rawTarget = manualCustomTargetIRE ?? 0
        }
        // Preserve the captured/calibrated target at full precision for all stop
        // math. Manual operation does not require landing the displayed decimal:
        // the UI rounds the label while the tolerance/hold logic remains centered
        // on this exact value (Log3G10 18% gray = 33.333291 IRE).
        let target = rawTarget
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
        fullScreenNodeID = nil
        manualStatus = String(format: "Target locked at %.0f IRE — select a camera and trim its lens.", target)
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

    private func manualQualityInvariantFailure(
        _ parts: [CameraNode],
        expected: Int
    ) -> String? {
        guard arrayActualQuality == expected else {
            return "participant quality proof was invalidated; re-verify the array."
        }
        if let changed = parts.first(where: {
            $0.status.livestreamQuality != expected
        }) {
            let actual = changed.status.livestreamQuality
                .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
            return "\(manualIDKey(changed)) changed livestream quality to \(actual)."
        }
        return nil
    }

    /// Wait for a locally-woken camera to prove the full measurement path: live
    /// HTTP transport plus three new native-frame ROI readings. A cached sphere
    /// value from the solve pass cannot satisfy this gate.
    private func waitForManualCameraReady(
        _ node: CameraNode,
        after epoch: Date
    ) async -> Bool {
        guard let samples = await collectManualSamples(
            node,
            after: epoch,
            count: 3,
            timeout: Self.manualReadyGrace
        ) else {
            return false
        }
        manualRecentIRE[node.id] = samples
        manualLastMeasurementAt[node.id] = node.sphere.measuredAt
        return !node.streamRecovering
            && node.stream.stats.width == NativeIREProbe.requiredSourceWidth
            && node.stream.stats.height == NativeIREProbe.requiredSourceHeight
    }

    /// Collect unique native-ROI measurements newer than `epoch`. The short
    /// rolling median rejects an isolated JPEG outlier without implying that
    /// independent cameras are frame-synchronous.
    private func collectManualSamples(
        _ node: CameraNode,
        after epoch: Date,
        count: Int,
        timeout: TimeInterval
    ) async -> [Double]? {
        let deadline = Date().addingTimeInterval(timeout)
        var samples: [Double] = []
        var lastSeen: Date?
        while Date() < deadline, !manualEndRequested, !Task.isCancelled {
            if node.stream.isStreaming,
               (node.sphere.phase == .locked || node.sphere.phase == .coasting),
               let measuredAt = node.sphere.measuredAt,
               measuredAt > epoch,
               measuredAt != lastSeen,
               let ire = node.sphere.heroIRE {
                samples.append(ire)
                lastSeen = measuredAt
                if samples.count >= count { return samples }
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    private func updateManualMatch(_ parts: [CameraNode]) {
        guard let target = manualTargetIRE else { return }
        guard manualPhase == .trimming else {
            if manualPhase == .complete {
                for node in parts where node.streamRole != .parked {
                    node.setStreamRole(.parked)
                }
            }
            return
        }
        let now = Date()

        // Catch a camera-side or restart read-back that diverges after
        // preflight. The UI quality controls are already locked, but a mixed
        // actual quality must also stop certification instead of being logged
        // and silently measured.
        guard let expected = manualExpectedQuality else {
            manualEndWasFailure = true
            manualEndMessage = "Measurement stopped: livestream quality proof was lost."
            manualEndRequested = true
            manualArrayStableSince = nil
            log("manual match: quality invariant LOST — \(manualEndMessage)")
            return
        }
        guard arrayActualQuality == expected else {
            manualEndWasFailure = true
            manualEndMessage =
                "Measurement stopped: participant quality proof was invalidated; re-verify the array."
            manualEndRequested = true
            manualArrayStableSince = nil
            log("manual match: quality invariant LOST — \(manualEndMessage)")
            return
        }
        if let changed = parts.first(where: {
            $0.status.livestreamQuality != expected
        }) {
            let actual = changed.status.livestreamQuality
                .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
            manualEndWasFailure = true
            manualEndMessage =
                "Measurement stopped: \(manualIDKey(changed)) changed livestream quality to \(actual)."
            manualEndRequested = true
            manualArrayStableSince = nil
            log("manual match: quality invariant LOST — \(manualEndMessage)")
            return
        }

        // At most two local readers are open while trimming: the camera under
        // the operator's hand plus the next uncertified camera warming for a
        // quick handoff. Every other camera-side encoder and RCP session remains
        // untouched while its local HTTP reader is intentionally parked.
        applyManualStreamSchedule(parts)

        guard let focusID = fullScreenNodeID,
              let focused = parts.first(where: { $0.id == focusID }) else {
            manualMatchedCount = manualCertified.count
            manualCommonDriftStops = nil
            updateManualArraySpread(parts)
            manualStatus = String(
                format: "%d/%d certified — select a camera to begin aperture matching.",
                manualMatchedCount,
                manualParticipantCount
            )
            return
        }

        var focusJustCertified = false

        for node in parts {
            if node.streamRole == .parked {
                manualStableSince.removeValue(forKey: node.id)
                if manualCertified.contains(node.id) {
                    node.manualMatch.phase = .matched
                    node.manualMatch.stability = 1
                    node.manualMatch.detail = "certified; local stream parked"
                } else {
                    node.manualMatch.phase = .acquiring
                    node.manualMatch.stability = 0
                    node.manualMatch.detail = "waiting for operator focus"
                }
                continue
            }

            let frameTimeout = node.streamRole == .focused
                ? Self.focusedStreamStallTimeout
                : Self.warmStreamStallTimeout
            let transportFresh = node.connected
                && node.stream.isStreaming
                && node.stream.stats.lastFrameAt.map {
                    now.timeIntervalSince($0) <= frameTimeout
                } == true

            var measurementAdvanced = false
            var measurementGap: TimeInterval?
            let measurementFresh: Bool
            if let measuredAt = node.sphere.measuredAt {
                let measurementTimeout = node.streamRole == .focused
                    ? Self.focusedMeasurementContinuity
                    : 1.5
                measurementFresh = now.timeIntervalSince(measuredAt) <= measurementTimeout
                if measurementFresh, measuredAt != manualLastMeasurementAt[node.id],
                   let ire = node.sphere.heroIRE {
                    measurementAdvanced = true
                    measurementGap = manualLastMeasurementAt[node.id].map {
                        measuredAt.timeIntervalSince($0)
                    }
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

            let sphereFresh = (node.sphere.phase == .locked || node.sphere.phase == .coasting)
                && measurementFresh

            guard transportFresh, sphereFresh, !node.streamRecovering,
                  let current = median(manualRecentIRE[node.id] ?? []),
                  let baseline = node.manualMatch.baselineIRE else {
                manualStableSince.removeValue(forKey: node.id)
                node.manualMatch.stability = 0
                if node.streamRole == .focused {
                    invalidateManualCertificationQualityProof()
                    manualCertified.remove(node.id)
                    node.manualMatch.phase = .recovering
                    node.manualMatch.currentIRE = nil
                    node.manualMatch.correctionStops = nil
                    node.manualMatch.deltaIRE = nil
                    node.manualMatch.detail = transportFresh
                        ? "waiting for three fresh native ROI measurements"
                        : "reopening focused local stream"
                    if !transportFresh {
                        requestStreamRecovery(node, now: now)
                    }
                } else {
                    node.manualMatch.phase = .acquiring
                    node.manualMatch.currentIRE = nil
                    node.manualMatch.correctionStops = nil
                    node.manualMatch.deltaIRE = nil
                    node.manualMatch.detail = transportFresh
                        ? "warming native ROI measurements"
                        : "warming next local stream"
                    if !transportFresh {
                        requestStreamRecovery(node, now: now)
                    }
                }
                continue
            }

            let correction = Log3G10.stops(between: target, and: current)
            guard correction.isFinite else {
                manualStableSince.removeValue(forKey: node.id)
                if node.id == focused.id {
                    invalidateManualCertificationQualityProof()
                }
                if manualCertified.remove(node.id) != nil {
                    log("manual match: \(manualIDKey(node)) certification withdrawn — invalid Log3G10 measurement")
                }
                node.manualMatch.currentIRE = nil
                node.manualMatch.correctionStops = nil
                node.manualMatch.deltaIRE = nil
                node.manualMatch.stability = 0
                node.manualMatch.phase = .unavailable
                node.manualMatch.detail = "invalid Log3G10 measurement"
                continue
            }

            node.manualMatch.currentIRE = current
            node.manualMatch.targetIRE = target
            node.manualMatch.correctionStops = correction
            node.manualMatch.deltaIRE = current - target
            node.manualMatch.baselineIRE = baseline
            node.manualMatch.toleranceStops = manualToleranceStops

            // A warm camera proves the next HTTP/native-measurement path is
            // ready, but it cannot earn calibration while nobody is watching or
            // touching its lens. Only fullscreen focus accrues the hold.
            guard node.id == focused.id else {
                manualStableSince.removeValue(forKey: node.id)
                node.manualMatch.stability = 0
                node.manualMatch.phase = .acquiring
                node.manualMatch.detail = abs(correction) <= manualToleranceStops
                    ? "next camera ready; focus required to certify"
                    : "next camera stream warm"
                continue
            }

            if abs(correction) <= manualToleranceStops {
                // Certification time advances only when a new native ROI
                // measurement arrives. A stalled image therefore freezes, then
                // resets, the hold instead of letting wall-clock time complete it.
                guard measurementAdvanced else {
                    if manualStableSince[node.id] == nil {
                        node.manualMatch.stability = 0
                        node.manualMatch.phase = .acquiring
                        node.manualMatch.detail = "waiting for the next focused measurement"
                    }
                    continue
                }
                if let measurementGap,
                   measurementGap > Self.focusedMeasurementContinuity {
                    manualStableSince.removeValue(forKey: node.id)
                    node.manualMatch.stability = 0
                }
                let since = manualStableSince[node.id] ?? now
                manualStableSince[node.id] = since
                let progress = min(1, now.timeIntervalSince(since) / max(0.1, manualHoldSeconds))
                node.manualMatch.stability = progress
                node.manualMatch.phase = progress >= 1 ? .matched : .hold
                node.manualMatch.detail = progress >= 1
                    ? "stable inside tolerance"
                    : String(format: "hold steady %.1fs", max(0, manualHoldSeconds - now.timeIntervalSince(since)))
                if progress >= 1, !manualCertified.contains(node.id) {
                    if manualCertificationQualityApprovedID == node.id {
                        manualCertified.insert(node.id)
                        focusJustCertified = true
                        log("manual match: \(manualIDKey(node)) certified after \(String(format: "%.1f", manualHoldSeconds))s focused hold")
                        soak.recordMatchEvent(
                            "manual_camera_certified",
                            cameraIP: node.ip,
                            finalSpreadStops: manualArraySpreadStops,
                            detail: String(format: "correction %+.3f stop", correction)
                        )
                    } else {
                        node.manualMatch.phase = .hold
                        node.manualMatch.detail = "verifying actual stream quality"
                        requestManualCertificationQualityProof(
                            for: node,
                            expected: expected
                        )
                    }
                }
            } else {
                invalidateManualCertificationQualityProof()
                if manualCertified.remove(node.id) != nil {
                    log("manual match: \(manualIDKey(node)) certification withdrawn before proceed")
                }
                manualStableSince.removeValue(forKey: node.id)
                node.manualMatch.stability = 0
                node.manualMatch.phase = correction > 0 ? .open : .close
                node.manualMatch.detail = correction > 0
                    ? String(format: "open iris %.2f stop", abs(correction))
                    : String(format: "close iris %.2f stop", abs(correction))
            }
        }

        manualMatchedCount = manualCertified.count
        manualCommonDriftStops = nil
        updateManualArraySpread(parts)

        if focusJustCertified, manualAdvanceMode == .automatic {
            proceedManualMatch()
            return
        }

        switch focused.manualMatch.phase {
        case .recovering:
            manualStatus = "\(manualIDKey(focused)): HOLD - RECOVERING"
        case .matched:
            if manualCertificationQualityTask != nil {
                manualStatus =
                    "\(manualIDKey(focused)): verifying actual livestream quality before proceed…"
            } else {
                manualStatus = manualAdvanceMode == .operatorProceed
                    ? "\(manualIDKey(focused)) certified — proceed when ready."
                    : "\(manualIDKey(focused)) certified."
            }
        case .hold:
            if focused.manualMatch.stability >= 1,
               manualCertificationQualityTask != nil {
                manualStatus =
                    "\(manualIDKey(focused)): verifying final actual livestream quality…"
            } else {
                manualStatus = String(
                    format: "%d/%d certified — %@: hold steady %.1fs.",
                    manualMatchedCount,
                    manualParticipantCount,
                    manualIDKey(focused),
                    max(0, manualHoldSeconds * (1 - focused.manualMatch.stability))
                )
            }
        case .open, .close:
            manualStatus = String(
                format: "%d/%d certified — %@: %@.",
                manualMatchedCount,
                manualParticipantCount,
                manualIDKey(focused),
                focused.manualMatch.detail
            )
        case .acquiring:
            manualStatus = "\(manualIDKey(focused)): acquiring fresh native ROI measurements…"
        case .idle, .unavailable:
            manualStatus = "\(manualIDKey(focused)): waiting for a usable focused stream…"
        }
    }

    /// Apply the local-resource policy for the trimming stage. Role changes from
    /// parked → warm/focused are HTTP-only and deliberately invalidate cached
    /// rolling samples so guidance cannot resume on a pre-park value.
    private func applyManualStreamSchedule(_ parts: [CameraNode]) {
        guard manualPhase == .trimming else { return }
        let focused = fullScreenNodeID.flatMap { id in
            parts.first(where: { $0.id == id })
        }
        let warm = focused.flatMap {
            nextUncertifiedManualCamera(after: $0, in: parts)
        }
        let now = Date()
        var desiredRoles: [UUID: CameraNode.StreamRole] = [:]
        for node in parts {
            if node.id == focused?.id {
                desiredRoles[node.id] = .focused
            } else if node.id == warm?.id {
                desiredRoles[node.id] = .warm
            } else {
                desiredRoles[node.id] = .parked
            }
        }

        // Shed the previous focus first, then promote/wake. This keeps the hard
        // local-reader ceiling at two even during the handoff itself.
        for node in parts where desiredRoles[node.id] == .parked {
            transitionManualStreamRole(node, to: .parked, now: now)
        }
        for node in parts {
            guard let role = desiredRoles[node.id], role != .parked else { continue }
            transitionManualStreamRole(node, to: role, now: now)
        }
    }

    private func transitionManualStreamRole(
        _ node: CameraNode,
        to desiredRole: CameraNode.StreamRole,
        now: Date
    ) {
        guard node.streamRole != desiredRole else { return }
        if desiredRole == .focused
            || (node.streamRole == .focused && desiredRole != .focused) {
            invalidateManualCertificationQualityProof()
        }
        if desiredRole == .focused,
           manualCertified.remove(node.id) != nil {
            manualMatchedCount = manualCertified.count
            manualStableSince.removeValue(forKey: node.id)
            node.manualMatch.phase = .acquiring
            node.manualMatch.stability = 0
            node.manualMatch.detail = "operator revisit — focused revalidation required"
            log("manual match: \(manualIDKey(node)) reopened for focused revalidation")
        }
        let wasParked = node.streamRole == .parked
        if desiredRole == .parked {
            manualStableSince.removeValue(forKey: node.id)
            streamRetryCount.removeValue(forKey: node.id)
            streamLastRetryAt.removeValue(forKey: node.id)
        } else if wasParked {
            manualRecentIRE[node.id] = []
            manualLastMeasurementAt.removeValue(forKey: node.id)
            // CameraNode performs wake attempt 1. Seed the shared retry gate so
            // the watchdog/guidance loop cannot immediately duplicate it.
            streamRetryCount[node.id] = 1
            streamLastRetryAt[node.id] = now
        }
        node.setStreamRole(desiredRole)
    }

    private func updateManualArraySpread(_ parts: [CameraNode]) {
        let latestKnownIRE = parts.compactMap { $0.manualMatch.currentIRE }.sorted()
        if let lo = latestKnownIRE.first, let hi = latestKnownIRE.last,
           latestKnownIRE.count >= 2 {
            let spread = abs(Log3G10.stops(between: lo, and: hi))
            manualArraySpreadStops = spread.isFinite ? spread : nil
        } else {
            manualArraySpreadStops = nil
        }
    }

    private func invalidateManualCertificationQualityProof() {
        guard manualCertificationQualityTask != nil
                || manualCertificationQualityApprovedID != nil else {
            return
        }
        manualCertificationQualityGeneration &+= 1
        manualCertificationQualityTask?.cancel()
        manualCertificationQualityTask = nil
        manualCertificationQualityApprovedID = nil
    }

    /// Final, read-only focused-camera quality proof. RCP2 does not advertise
    /// explicit subscription support for LIVESTREAM_QUALITY, so this uses the
    /// documented rcp_get path and CameraActor removes the implicit subscription
    /// residue immediately afterward.
    private func requestManualCertificationQualityProof(
        for node: CameraNode,
        expected: Int
    ) {
        guard manualCertificationQualityApprovedID != node.id,
              manualCertificationQualityTask == nil,
              let camera = node.camera else {
            return
        }
        manualCertificationQualityGeneration &+= 1
        let generation = manualCertificationQualityGeneration
        let nodeID = node.id
        let nodeName = manualIDKey(node)
        manualCertificationQualityTask = Task { [weak self] in
            let actual = await camera.readLivestreamQuality()
            guard let self, !Task.isCancelled,
                  self.manualCertificationQualityGeneration == generation,
                  self.manualPhase == .trimming,
                  self.fullScreenNodeID == nodeID else {
                return
            }
            self.manualCertificationQualityTask = nil
            guard actual == expected else {
                let actualLabel = actual
                    .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
                self.manualCertificationQualityApprovedID = nil
                self.manualEndWasFailure = true
                self.manualEndMessage =
                    "Measurement stopped: \(nodeName) returned \(actualLabel) at certification."
                self.manualEndRequested = true
                self.log("manual match: quality invariant LOST — \(self.manualEndMessage)")
                return
            }
            self.manualCertificationQualityApprovedID = nodeID
            self.log("manual match: \(nodeName) final actual livestream quality confirmed")
        }
    }

    /// UI gate for the explicit Operator Proceed mode. The four-second hold is
    /// necessary but not sufficient: the focused stream must still be fresh at
    /// the instant the operator approves the handoff.
    func canProceedManualMatch(from node: CameraNode) -> Bool {
        guard manualPhase == .trimming,
              fullScreenNodeID == node.id,
              manualCertified.contains(node.id),
              manualCertificationQualityApprovedID == node.id,
              manualCertificationQualityTask == nil,
              let expected = manualExpectedQuality,
              arrayActualQuality == expected,
              manualParticipants.allSatisfy({
                  $0.status.livestreamQuality == expected
              }),
              node.manualMatch.phase == .matched,
              node.streamRole == .focused,
              !node.streamRecovering,
              node.stream.isStreaming,
              let frameAt = node.stream.stats.lastFrameAt,
              Date().timeIntervalSince(frameAt) <= Self.focusedStreamStallTimeout,
              let measuredAt = node.sphere.measuredAt,
              Date().timeIntervalSince(measuredAt) <= Self.focusedMeasurementContinuity else {
            return false
        }
        return true
    }

    func manualProceedTitle(from node: CameraNode) -> String {
        nextUncertifiedManualCamera(after: node, in: manualParticipants)
            .map { "Proceed to \(manualIDKey($0))" }
            ?? "Complete Calibration"
    }

    /// Shared handoff used by both Automatic and Operator Proceed. Automatic
    /// invokes it immediately after the same four-second certification that
    /// enables the operator's button.
    func proceedManualMatch() {
        guard manualPhase == .trimming,
              let focused = fullScreenNode else {
            return
        }
        if manualAdvanceMode == .operatorProceed {
            requestOperatorProceedQualityProof(for: focused)
        } else {
            advanceManualMatch(from: focused)
        }
    }

    /// Operator Proceed may happen long after the four-second hold completed.
    /// Re-read the focused camera's actual factor at the click instead of
    /// accepting an arbitrarily old, unsubscribed proof. This is one bounded
    /// read per handoff—not background polling.
    private func requestOperatorProceedQualityProof(for node: CameraNode) {
        guard canProceedManualMatch(from: node),
              let expected = manualExpectedQuality,
              let camera = node.camera else {
            return
        }
        manualCertificationQualityGeneration &+= 1
        let generation = manualCertificationQualityGeneration
        let nodeID = node.id
        let nodeName = manualIDKey(node)
        manualCertificationQualityApprovedID = nil
        manualStatus =
            "\(nodeName): verifying actual livestream quality before proceed…"
        manualCertificationQualityTask = Task { [weak self] in
            let actual = await camera.readLivestreamQuality()
            guard let self, !Task.isCancelled,
                  self.manualCertificationQualityGeneration == generation,
                  self.manualPhase == .trimming,
                  self.fullScreenNodeID == nodeID else {
                return
            }
            self.manualCertificationQualityTask = nil
            guard actual == expected else {
                let actualLabel = actual
                    .flatMap { RCP2.livestreamQualityLabels[$0] }
                    ?? "NO READ-BACK"
                self.manualEndWasFailure = true
                self.manualEndMessage =
                    "Measurement stopped: \(nodeName) returned \(actualLabel) before proceed."
                self.manualEndRequested = true
                self.log("manual match: quality invariant LOST — \(self.manualEndMessage)")
                return
            }
            self.manualCertificationQualityApprovedID = nodeID
            guard let current = self.fullScreenNode,
                  self.canProceedManualMatch(from: current) else {
                self.manualStatus =
                    "\(nodeName): quality confirmed; waiting for a fresh focused measurement…"
                return
            }
            self.log("manual match: \(nodeName) operator-proceed actual quality confirmed")
            self.advanceManualMatch(from: current)
        }
    }

    private func advanceManualMatch(from focused: CameraNode) {
        guard canProceedManualMatch(from: focused) else { return }
        if let next = nextUncertifiedManualCamera(
            after: focused,
            in: manualParticipants
        ) {
            manualStatus = "\(manualIDKey(focused)) certified — warming \(manualIDKey(next))…"
            focusManual(on: next)
        } else {
            completeManualCalibration()
        }
    }

    private func completeManualCalibration() {
        guard manualPhase == .trimming,
              manualCertified.count == manualParticipantCount else {
            return
        }
        manualMatchedCount = manualCertified.count
        manualPhase = .complete
        fullScreenNodeID = nil
        for node in manualParticipants {
            node.setStreamRole(.parked)
            streamRetryCount.removeValue(forKey: node.id)
            streamLastRetryAt.removeValue(forKey: node.id)
        }
        manualStatus =
            "All \(manualParticipantCount) cameras certified sequentially — Finish & Restore when ready."
        log("manual match: VERIFY PASS — every participant completed its focused \(String(format: "%.1f", manualHoldSeconds))s hold")
        soak.recordMatchEvent(
            "manual_match_verified",
            finalSpreadStops: manualArraySpreadStops,
            detail: "all cameras certified sequentially"
        )
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
        let changed = manualChangedOutputs.count
        for node in nodes where manualChangedOutputs.contains(node.id) {
            guard let camera = node.camera, let saved = manualSavedTransforms[node.id] else {
                failed.append(node.ip)
                continue
            }
            // Delayed retries are compare-before-set: restore only when the
            // same mirrored output is still app-owned Log3G10 (or is already at
            // the saved preset). Never overwrite a newer operator choice.
            if await camera.restoreMonitorTransform(saved) {
                restored += 1
                manualChangedOutputs.remove(node.id)
                manualSavedTransforms.removeValue(forKey: node.id)
            } else {
                failed.append(node.ip)
            }
        }

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
        let failureText: String
        if !failed.isEmpty {
            failureText =
                " Restore requires attention: \(failed.joined(separator: ", ")). Reconnect, then retry output restore."
        } else if manualRestorePending {
            failureText =
                " \(manualChangedOutputs.count) output restore(s) remain pending."
        } else {
            failureText = ""
        }
        manualStatus = "\(manualEndMessage) \(restoreText)\(failureText)"
        manualPhase = (manualEndWasFailure || manualRestorePending) ? .failed : .finished
        log("manual match: END — \(manualStatus)")
        soak.recordMatchEvent("manual_match_end",
                              finalSpreadStops: manualArraySpreadStops,
                              detail: manualStatus)

        // Release the masks we froze for the swap so normal tracking resumes.
        for node in nodes where manualFrozenNodes.contains(node.id) {
            node.unfreezeTransformLock()
        }
        // Leave Manual Assist participants locally parked after restore. Their
        // camera-side livestream enable/quality and RCP sessions remain intact;
        // a later explicit Stream All can wake readers HTTP-only.
        for node in nodes where manualParticipantIDs.contains(node.id) {
            node.setStreamRole(.parked)
            streamRetryCount.removeValue(forKey: node.id)
            streamLastRetryAt.removeValue(forKey: node.id)
        }

        manualFrozenNodes.removeAll()
        manualCertified.removeAll()
        invalidateManualCertificationQualityProof()
        if manualChangedOutputs.isEmpty {
            manualSavedTransforms.removeAll()
            manualEnteredTransformStage = false
        } else {
            manualSavedTransforms = manualSavedTransforms.filter {
                manualChangedOutputs.contains($0.key)
            }
        }
        manualStableSince.removeAll()
        manualArrayStableSince = nil
        manualEndRequested = false
        manualEndWasFailure = false
        manualExpectedQuality = nil
        manualTask = nil
        qualityControlsLocked = false
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
        guard loopTask == nil, manualTask == nil, !manualSessionActive,
              !manualRestorePending, !qualityControlsLocked else { return }
        matchWorkflow = .electronic
        qualityControlsLocked = true
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
            qualityControlsLocked = false
        }

        guard parts.count >= 2 || (parts.count == 1 && referenceMode == .hero) else {
            loopState = .finished("need ≥2 participating cameras (connected + e-iris + streaming + sphere locked)")
            log("match loop: not enough participants")
            return
        }
        guard await verifyUniformLivestreamQuality(parts, requested: arrayQuality,
                                                   context: "Electronic Match preflight") else {
            loopState = .finished("livestream quality mismatch: actual read-backs must be identical")
            log("match loop: quality preflight BLOCKED — \(arrayQualityStatus)")
            return
        }
        guard let expectedQuality = arrayActualQuality else {
            loopState = .finished("livestream quality proof disappeared after preflight")
            log("match loop: quality invariant LOST immediately after preflight")
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
            guard arrayActualQuality == expectedQuality else {
                loopState = .finished(
                    "livestream quality proof was invalidated; re-verify the participants"
                )
                log("match loop: quality invariant LOST — \(arrayQualityStatus)")
                return
            }
            if let changed = parts.first(where: {
                $0.status.livestreamQuality != expectedQuality
            }) {
                let actual = changed.status.livestreamQuality
                    .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
                loopState = .finished(
                    "livestream quality changed on \(changed.displayName) to \(actual)"
                )
                log("match loop: quality invariant LOST — \(changed.displayName) actual \(actual)")
                return
            }
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
            // A stream restart can complete while the freshness wait is in
            // flight. Re-check after it so no iris correction is ever planned
            // from a frame whose actual JPEG quality has just diverged.
            guard arrayActualQuality == expectedQuality else {
                loopState = .finished(
                    "livestream quality proof was invalidated during measurement freshness wait"
                )
                log("match loop: quality invariant LOST after freshness gate — \(arrayQualityStatus)")
                return
            }
            if let changed = parts.first(where: {
                $0.status.livestreamQuality != expectedQuality
            }) {
                let actual = changed.status.livestreamQuality
                    .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
                loopState = .finished(
                    "livestream quality changed on \(changed.displayName) to \(actual)"
                )
                log("match loop: quality invariant LOST after freshness gate — \(changed.displayName) actual \(actual)")
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
