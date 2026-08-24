//  ArrayView.swift — R3DIris / Array (Phase 2)
//  The Iris Match surface, in R3DIris's own identity (UI/Theme.swift):
//  discovery toolbar (CAMINFO broadcast primary, TCP sweep fill-in, manual IP
//  as the fallback path) · camera-tile grid (live view + sphere overlay + aperture
//  state) · Iris Match / Exposure Match panels · waveform · array log.
//  Root chrome (background, logo, tab switcher) lives in ContentView.

import SwiftUI

struct ArrayView: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        ZStack {
            arrayContent
            if let fs = array.fullScreenNode {
                FullscreenCameraView(node: fs)
                    .transition(.opacity)
            }
        }
        // Hands-free: sweep for cameras when the Array tab first appears and
        // nothing is set up yet. Guarded so switching back to the tab with an
        // array already running (or discovering) doesn't re-sweep.
        .task {
            if array.nodes.isEmpty && array.discovered.isEmpty && !array.discovering {
                array.discover()
            }
        }
    }

    var arrayContent: some View {
        VStack(spacing: 0) {
            DiscoveryBar()
            if !array.discovered.isEmpty {
                DiscoveredStrip()
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HSplitView {
                VStack(spacing: 0) {
                    CameraGrid()
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ArrayLogPane()
                        .frame(minHeight: 110, idealHeight: 160)
                }
                .frame(minWidth: 520)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ArrayActionsPanel()
                        MatchWorkflowPanel()
                        switch array.matchWorkflow {
                        case .electronic:
                            IrisMatchPanel()
                            MatchLoopPanel()
                        case .hybrid:
                            ManualAssistPanel()
                        case .calibrate:
                            CalibrationPanel()
                        }
                        SoakPanel(soak: array.soak)
                        if let node = array.selectedNode {
                            WaveformPanel(node: node)
                        }
                        Spacer()
                    }
                    .padding(14)
                }
                .frame(minWidth: 330, idealWidth: 370, maxWidth: 450)
                .background(Theme.bg1.opacity(0.6))
            }
        }
    }
}

// MARK: - Discovery toolbar

struct DiscoveryBar: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        HStack(spacing: 10) {
            // Discovery cluster — the primary way cameras enter the array.
            // Empty = auto-detect this Mac's subnets; typing overrides.
            TextField("subnet (auto)", text: $array.subnet)
                .darkField()
                .frame(width: 150)
                .onSubmit { array.discover() }
                .disabled(array.discovering)
                .help("Leave empty: Detect Cameras sweeps the subnets of this Mac's own network interfaces. Enter a CIDR only to override (routed arrays, unusual topologies).")
            TextField("source IP (rule 16)", text: $array.sourceIP)
                .darkField()
                .frame(width: 140)
                .disabled(array.discovering)
            Button {
                array.discover()
            } label: {
                HStack(spacing: 5) {
                    if array.discovering {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                    }
                    Text(array.discovering ? "Scanning…" : "Detect Cameras")
                }
            }
            .buttonStyle(DarkButtonStyle(prominent: true))
            .disabled(array.discovering)
            .help(scanHelp)

            Rectangle().fill(Theme.line).frame(width: 1, height: 20)

            // Manual entry — fallback when discovery can't see the body.
            TextField("manual IP", text: $array.newIP)
                .darkField()
                .frame(width: 120)
                .onSubmit { array.addCamera() }
            Button("Add") { array.addCamera() }
                .buttonStyle(DarkButtonStyle())
                .help("Fallback: add a camera discovery can't reach (cross-subnet routes, unusual NIC setups).")

            Spacer()

            HStack(spacing: 6) {
                StatusDot(level: connectedCount > 0 ? .ok : .off)
                Text("\(connectedCount)/\(array.nodes.count) connected")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel2.opacity(0.7))
    }

    var connectedCount: Int { array.nodes.filter(\.connected).count }

    var scanHelp: String {
        let n = array.subnetHostCount
        return n > 0
            ? "TCP sweep of \(n) host(s) on :9998 (no session-slot cost), CAMINFO broadcast fallback."
            : "Auto: sweeps this Mac's own subnet(s) on :9998, CAMINFO broadcast fallback. Type a CIDR to override."
    }
}

// MARK: - Discovered strip

struct DiscoveredStrip: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        HStack(spacing: 8) {
            Text("DISCOVERED")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Theme.warn)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(array.discovered) { cam in
                        Button {
                            array.addDiscovered(cam)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.good)
                                Text(cam.ip).font(Theme.mono(11, weight: .semibold))
                                if !cam.label.isEmpty {
                                    Text(cam.label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.ink3)
                                }
                                if !cam.firmware.isEmpty {
                                    Text("FW \(cam.firmware)")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(Theme.ink3)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel3))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Add \(cam.ip) to the array")
                    }
                }
            }
            Button("Add All") { array.addAllDiscovered() }
                .buttonStyle(DarkButtonStyle(prominent: true))
            Button("Dismiss") { array.dismissDiscovered() }
                .buttonStyle(DarkButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.warnBG.opacity(0.5))
    }
}

// MARK: - Camera grid

struct CameraGrid: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                ForEach(array.nodes) { node in
                    CameraTile(node: node)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if array.nodes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "camera.metering.matrix")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.ink3)
                    Text("No cameras in the array")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                    Text("Detect Cameras sweeps the subnet on :9998 —\nor add an IP manually as a fallback.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct CameraTile: View {
    @EnvironmentObject var array: ArrayController
    @ObservedObject var node: CameraNode
    @ObservedObject var stream: MJPEGStreamReader

    init(node: CameraNode) {
        self.node = node
        self.stream = node.stream
    }

    var selected: Bool { array.selectedNodeID == node.id }

    var body: some View {
        VStack(spacing: 6) {
            // Live view
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusSm)
                    .fill(Color.black)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                if let frame = stream.frame {
                    Image(decorative: frame, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay { SphereOverlay(sphere: node.sphere) }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                } else {
                    Text(stream.isStreaming ? "waiting for frames…" : "no stream")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                }
                if array.usesOperatorGuidance, array.manualSessionActive,
                   node.manualMatch.phase != .idle {
                    ManualCameraHUD(info: node.manualMatch, selected: selected)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                if node.streamRole == .parked, node.streamingDesired {
                    VStack {
                        HStack {
                            Spacer()
                            Text("PARKED • LAST FRAME")
                                .font(Theme.mono(8.5, weight: .bold))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.78)))
                        }
                        Spacer()
                    }
                    .padding(7)
                    .allowsHitTesting(false)
                }
            }

            // Identity row
            HStack(spacing: 7) {
                StatusDot(level: linkLevel)
                Text(node.status.displayID.isEmpty ? node.ip : node.status.displayID)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !node.status.displayID.isEmpty {
                    Text(node.ip)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer()
                Text(node.status.currentTC.isEmpty ? "--:--:--" : node.status.currentTC)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(node.status.tcLock ? Theme.ink2 : Theme.warn)
                    .help("TC push at 1/s = link alive. Amber = no recent TC (possible wedge).")
            }

            // Readings row
            HStack(spacing: 7) {
                apertureChip
                sphereChip
                transformChip
                if node.streamStale {
                    Text("STALE")
                        .font(Theme.mono(9, weight: .bold))
                        .foregroundStyle(Theme.warn)
                        .help("Livestream frozen — frames stopped changing. Check the camera feed / mirror source.")
                }
                Spacer()
                // Working through 36 bodies, "is this one done?" must be
                // answerable at a glance without opening the roll.
                if array.calibrateMode,
                   array.calibrationPrewarmedIDs.contains(node.id) {
                    Text("READY")
                        .font(Theme.mono(9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentBG))
                        .help("Warmed ahead of its turn: stream live and output already in the calibration transform. The run will not wait on it.")
                }
                if array.calibrateMode, array.isInCalibrationRoll(node) {
                    Text("ROLL")
                        .font(Theme.mono(9, weight: .bold))
                        .foregroundStyle(Theme.good)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.goodBG))
                        .help("Recorded in the calibration roll. Re-calibrating replaces its row.")
                }
                matchChip
            }

            // Actions row
            HStack(spacing: 6) {
                if !node.connected {
                    Button("Connect") {
                        let src = array.sourceIP.trimmingCharacters(in: .whitespaces)
                        node.connect(sourceIP: src.isEmpty ? nil : src)
                    }
                    .buttonStyle(DarkButtonStyle(prominent: true))
                    if node.status.link == .parked {
                        Button("Refresh") { node.refresh() }
                            .buttonStyle(DarkButtonStyle())
                    }
                } else {
                    Button(stream.isStreaming ? "Stop Stream" : "Stream") {
                        if stream.isStreaming { node.stopStream() } else { node.startStream() }
                    }
                    .buttonStyle(DarkButtonStyle())
                    // One-click accept of a good auto-detected mask — no need to
                    // open the camera and click the sphere.
                    if node.sphere.hasROI, !node.sphere.seeded {
                        Button("Lock Mask") { array.acceptAutoMask(node) }
                            .buttonStyle(DarkButtonStyle(prominent: true))
                            .help("Accept the current auto-detected mask as the seed.")
                    }
                    Button("Re-detect") { node.redetect() }
                        .buttonStyle(DarkButtonStyle())
                        .disabled(!stream.isStreaming)
                    // Starts the whole run AT this body, then continues down
                    // the array in IP order. The panel's button starts from the
                    // lowest IP instead.
                    if array.calibrateMode, !array.calibrationRunActive {
                        Button("Calibrate From Here") {
                            array.beginCalibrationRun(startingAt: node)
                        }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(!array.canStartRunHere(node))
                        .help("Begin the calibration run at this camera and continue through the rest of the array in IP order.")
                    }
                }
                Spacer()
                Button {
                    array.removeCamera(node)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(DarkButtonStyle(destructive: true))
                .help("Remove from array")
            }
            .disabled(array.manualSessionActive)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded {
            if array.manualSessionActive, array.isManualParticipant(node) {
                array.selectManualCamera(node)
            } else if !array.manualSessionActive {
                array.selectedNodeID = node.id
                array.fullScreenNodeID = node.id
            }
        })
        .simultaneousGesture(TapGesture().onEnded {
            if !array.manualSessionActive || array.fullScreenNodeID == node.id {
                array.selectedNodeID = node.id
            }
        })
        .help("Click: select · double-click: full screen")
    }

    var linkLevel: StatusDot.Level {
        switch node.status.link {
        case .connected: return .ok
        case .connecting: return .warn
        case .parked: return .fail
        case .disconnected: return .off
        }
    }

    var apertureChip: some View {
        HStack(spacing: 4) {
            Text("T").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
            Text(RCP2.stopLabel(node.status.apertureCur))
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if let cur = node.status.apertureCur, let tgt = node.status.apertureTarget, cur != tgt {
                Image(systemName: "arrow.right").font(.system(size: 7))
                    .foregroundStyle(Theme.warn)
                Text(RCP2.stopLabel(tgt))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.warn)
            }
            if node.eIris {
                Text("E").font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.goodBG))
                    .foregroundStyle(Theme.good)
                    .help("Electronic iris (APERTURE_CONTROL == 1)")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2))
    }

    var sphereChip: some View {
        HStack(spacing: 4) {
            Circle().fill(sphereColor).frame(width: 6, height: 6)
            if let ire = node.sphere.heroIRE {
                Text(String(format: "%.1f IRE", ire))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink)
            } else {
                Text(node.sphere.phase.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2))
        .help("Sphere: \(node.sphere.phase.rawValue) \(node.sphere.detail)")
    }

    var sphereColor: Color {
        switch node.sphere.phase {
        case .locked: return Theme.good
        case .coasting: return Theme.warn
        case .candidate: return Theme.accent
        case .searching: return Theme.idle
        }
    }

    var transformChip: some View {
        Text(node.status.monitorTransform.rawValue)
            .font(Theme.mono(8.5, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Capsule().fill(transformBG))
            .foregroundStyle(transformInk)
            .help(transformHelp)
    }

    var transformBG: Color {
        switch node.status.monitorTransform {
        case .log3G10: return Theme.accentBG
        case .ipp2: return Theme.warnBG
        case .unknown: return Theme.idleBG
        }
    }

    var transformInk: Color {
        switch node.status.monitorTransform {
        case .log3G10: return Theme.accent
        case .ipp2: return Theme.warn
        case .unknown: return Theme.idle
        }
    }

    var transformHelp: String {
        let pid = node.status.monitorTransformParam.isEmpty
            ? "active output unknown"
            : node.status.monitorTransformParam
        let value = node.status.monitorTransformValue.map(String.init) ?? "no value"
        return "Livestream viewing transform: \(pid) = \(value)."
    }

    @ViewBuilder
    var matchChip: some View {
        if array.usesOperatorGuidance, array.manualSessionActive,
           node.manualMatch.phase != .idle {
            Text(manualMatchLabel)
                .font(Theme.mono(10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(manualMatchBG))
                .foregroundStyle(manualMatchInk)
                .help(node.manualMatch.detail)
        } else if node.match.phase != .idle || node.match.manualOverride {
            Text(matchLabel)
                .font(Theme.mono(10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(matchBG))
                .foregroundStyle(matchInk)
                .help(node.match.note)
        }
    }

    var manualMatchLabel: String {
        guard let correction = node.manualMatch.correctionStops else {
            return node.manualMatch.phase.rawValue
        }
        return String(format: "%@ %.2fst", node.manualMatch.phase.rawValue, abs(correction))
    }

    var manualMatchBG: Color {
        switch node.manualMatch.phase {
        case .matched: return Theme.goodBG
        case .hold: return Theme.accentBG
        case .open, .close: return Theme.warnBG
        case .recovering: return Theme.warnBG
        case .unavailable: return Theme.dangerBG
        case .acquiring, .idle: return Theme.idleBG
        }
    }

    var manualMatchInk: Color {
        switch node.manualMatch.phase {
        case .matched: return Theme.good
        case .hold: return Theme.accent
        case .open, .close: return Theme.warn
        case .recovering: return Theme.warn
        case .unavailable: return Theme.danger
        case .acquiring, .idle: return Theme.idle
        }
    }

    var matchLabel: String {
        // A manually-overridden camera reads e.g. "MATCHED · OVERRIDE 1 close" so
        // the operator can see at a glance it was deliberately moved off the
        // computed match, and which way.
        if node.match.manualOverride {
            let n = node.match.overrideSteps
            let tail = n == 0 ? "" : (n < 0 ? " \(abs(n)) open" : " \(abs(n)) close")
            let base = node.match.phase == .idle ? "SET" : node.match.phase.rawValue.uppercased()
            return "\(base) · OVERRIDE\(tail)"
        }
        if array.loopUsesLog3G10, let d = node.match.deltaStops {
            return String(format: "%@ %+.3fst", node.match.phase.rawValue, d)
        }
        if let d = node.match.deltaIRE {
            return String(format: "%@ %+.1f", node.match.phase.rawValue, d)
        }
        return node.match.phase.rawValue
    }

    var matchBG: Color {
        if node.match.manualOverride { return Theme.accentBG }
        switch node.match.phase {
        case .matched: return Theme.goodBG
        case .adjusting: return Theme.accentBG
        case .capped, .oscillating: return Theme.warnBG
        case .excluded: return Theme.idleBG
        case .idle: return .clear
        }
    }

    var matchInk: Color {
        if node.match.manualOverride { return Theme.accent }
        switch node.match.phase {
        case .matched: return Theme.good
        case .adjusting: return Theme.accent
        case .capped, .oscillating: return Theme.warn
        case .excluded: return Theme.idle
        case .idle: return .clear
        }
    }
}

/// Live game-like guidance laid over the camera feed. The horizontal marker
/// is an exposure instruction, not a physical lens-rotation direction:
/// negative/left = CLOSE, positive/right = OPEN, center = fixed target.
// MARK: - Manual trim HUD kit
//
// Game-style operator guidance for hand-trimming an iris ring: marching
// chevrons show WHICH WAY and HOW FAR (1–3 by magnitude), a center-zero
// gauge with quarter-stop ticks shows position, the capture band is sized
// by the REAL session tolerance, and a hold-to-confirm ring fills while the
// reading stays inside the band. Clean, technical, no clutter — the cues
// are the interface.

/// Shared cue phase → color/icon mapping so tile HUD and focus card agree.
enum ManualCueStyle {
    static func icon(_ phase: ManualMatchInfo.Phase) -> String {
        switch phase {
        case .open: return "plus.circle"
        case .close: return "minus.circle"
        case .hold: return "target"
        case .matched: return "checkmark.circle.fill"
        case .recovering: return "arrow.clockwise.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .acquiring: return "viewfinder"
        case .idle: return "circle.dashed"
        }
    }

    static func color(_ phase: ManualMatchInfo.Phase) -> Color {
        switch phase {
        case .matched: return Theme.good
        case .hold: return Theme.accent
        case .open, .close: return Theme.warn
        case .recovering: return Theme.warn
        case .unavailable: return Theme.danger
        case .acquiring, .idle: return Theme.idle
        }
    }
}

/// UI-only progress cadence for a focused camera whose MJPEG reader is being
/// recovered. The dots animate locally; no controller timer or repeated log
/// message is needed to make recovery feel alive to the operator.
struct ManualRecoveryText: View {
    let size: CGFloat
    let label: String
    @State private var startedAt = Date()

    init(size: CGFloat, label: String = "HOLD - RECOVERING") {
        self.size = size
        self.label = label
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.45)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let tick = Int(elapsed / 0.45)
            let dots = tick % 3 + 1
            Text(label + String(repeating: ".", count: dots))
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .tracking(size >= 24 ? 3.0 : 1.4)
                .foregroundStyle(Theme.warn)
                .shadow(color: .black.opacity(0.85), radius: 4)
                .accessibilityLabel(label)
        }
    }
}

/// 1–3 chevrons by correction magnitude, marching in the trim direction.
/// `direction` +1 = open (right), −1 = close (left). Static when inactive.
struct TrimChevrons: View {
    let direction: Double
    let magnitudeStops: Double
    let color: Color

    private var count: Int {
        let m = abs(magnitudeStops)
        return m >= 0.75 ? 3 : m >= 0.25 ? 2 : 1
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t * 2.2).truncatingRemainder(dividingBy: 1.0)
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let order = direction >= 0 ? i : (2 - i)
                    let active = order < count
                    // Stagger the pulse along the march direction.
                    let local = (phase - Double(order) * 0.22)
                        .truncatingRemainder(dividingBy: 1.0)
                    let pulse = local >= 0 && local < 0.45 ? 1.0 : 0.35
                    Image(systemName: direction >= 0 ? "chevron.right" : "chevron.left")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(color.opacity(active ? pulse : 0.12))
                }
            }
        }
        .frame(width: 34)
    }
}

/// Hold-to-confirm ring: fills with `stability` while inside tolerance;
/// full + solid on matched. The "capture" affordance.
struct HoldRing: View {
    let phase: ManualMatchInfo.Phase
    let stability: Double
    var size: CGFloat = 24

    private var color: Color { ManualCueStyle.color(phase) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.line2, lineWidth: 2)
            Circle()
                .trim(from: 0, to: phase == .matched ? 1 : min(1, max(0, stability)))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: stability)
            Image(systemName: ManualCueStyle.icon(phase))
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .shadow(color: phase == .matched ? color.opacity(0.6) : .clear, radius: 4)
    }
}

/// Center-zero trim gauge, ±1 stop full scale: quarter-stop ticks, a capture
/// band sized by the session tolerance, and a spring-animated needle.
struct ManualTrimGauge: View {
    let correctionStops: Double?
    let toleranceStops: Double
    let color: Color
    var compact = false

    private static let fullScaleStops = 1.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barH: CGFloat = compact ? 6 : 8
            let midY = geo.size.height / 2
            let usable = w - 12
            let value = min(Self.fullScaleStops, max(-Self.fullScaleStops, correctionStops ?? 0))
            let needleX = w / 2 + usable / 2 * CGFloat(value / Self.fullScaleStops)
            let bandW = max(6, usable * CGFloat(min(1, toleranceStops / Self.fullScaleStops)))

            ZStack {
                // Track
                Capsule()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: usable + 12, height: barH)
                    .position(x: w / 2, y: midY)
                // Quarter-stop ticks
                ForEach(-4...4, id: \.self) { q in
                    let major = q == 0
                    Rectangle()
                        .fill(major ? Theme.ink2 : Theme.line2)
                        .frame(width: 1, height: major ? barH + 8 : barH + 3)
                        .position(x: w / 2 + usable / 2 * CGFloat(Double(q) / 4.0), y: midY)
                }
                // Capture band = real tolerance
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.good.opacity(0.30))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.good.opacity(0.6), lineWidth: 1))
                    .frame(width: bandW, height: barH + 6)
                    .position(x: w / 2, y: midY)
                // Needle
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: barH + 12)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    .position(x: needleX, y: midY)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: needleX)
                // End labels
                if !compact {
                    Text("CLOSE")
                        .font(.system(size: 7, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Theme.ink3)
                        .position(x: 18, y: midY + barH + 9)
                    Text("OPEN")
                        .font(.system(size: 7, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Theme.ink3)
                        .position(x: w - 18, y: midY + barH + 9)
                }
            }
        }
    }
}

struct ManualCameraHUD: View {
    let info: ManualMatchInfo
    let selected: Bool

    private var cueColor: Color { ManualCueStyle.color(info.phase) }
    private var trimming: Bool { info.phase == .open || info.phase == .close }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.55), .clear, Color.black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 4) {
                HStack {
                    Text("MANUAL TRIM")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(selected ? Theme.accent : Theme.ink2)
                    Spacer()
                    if let current = info.currentIRE, let target = info.targetIRE {
                        Text(String(format: "%.1f → %.0f", current, target))
                            .font(Theme.mono(9.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }

                Spacer(minLength: 0)

                // Cue line: phase + signed correction, hold ring at right.
                HStack(spacing: 8) {
                    if trimming {
                        TrimChevrons(direction: info.phase == .open ? 1 : -1,
                                     magnitudeStops: info.correctionStops ?? 0,
                                     color: cueColor)
                    }
                    Text(info.phase.rawValue)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(cueColor)
                    if let correction = info.correctionStops, trimming {
                        Text(String(format: "%+.2f ST", correction))
                            .font(Theme.mono(12, weight: .bold))
                            .foregroundStyle(cueColor)
                            .help("Signed iris move: + open, − close")
                    }
                    Spacer()
                    HoldRing(phase: info.phase, stability: info.stability, size: 22)
                }
                .shadow(color: cueColor.opacity(0.35), radius: 4)

                ManualTrimGauge(correctionStops: info.correctionStops.map { -$0 },
                                toleranceStops: info.toleranceStops,
                                color: cueColor,
                                compact: true)
                    .frame(height: 18)
            }
            .padding(9)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Theme.radiusSm)
                    .stroke(Theme.accent.opacity(0.75), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Fullscreen camera view (double-click a tile; Esc / double-click exits)

struct FullscreenCameraView: View {
    @EnvironmentObject var array: ArrayController
    @ObservedObject var node: CameraNode
    @ObservedObject var stream: MJPEGStreamReader

    init(node: CameraNode) {
        self.node = node
        self.stream = node.stream
    }

    private var manualActive: Bool {
        array.manualSessionActive && array.isManualParticipant(node)
    }

    /// Click-to-seed is normally locked out during a session. The calibrate run
    /// deliberately re-opens it for the focused body: seeding each camera when
    /// the run reaches it IS the flow.
    private var seedingAllowed: Bool {
        !manualActive
            || (array.calibrationAwaitingSeed && array.fullScreenNodeID == node.id)
    }

    private var manualRecovering: Bool {
        manualActive
            && array.manualPhase == .trimming
            && (node.manualMatch.phase == .recovering || node.streamRecovering)
    }

    private var manualWaking: Bool {
        manualActive && array.manualPhase == .preparing && node.streamRecovering
    }

    private var manualPaused: Bool {
        manualRecovering || manualWaking
    }

    var body: some View {
        ZStack {
            Color.black
            if let frame = stream.frame {
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(manualPaused ? 0.22 : 1)
                    .overlay {
                        // Manual trimming: the dial ring replaces the plain
                        // lock circle so the sphere stays fully visible.
                        if manualActive, array.manualPhase == .trimming,
                           !manualPaused {
                            IrisDialOverlay(sphere: node.sphere, info: node.manualMatch)
                        } else if !manualPaused, let seed = node.pendingSeed {
                            PendingSeedOverlay(seed: seed)
                        } else if !manualPaused {
                            SphereOverlay(sphere: node.sphere)
                        }
                    }
                    // Click-to-seed: outside a manual session, clicking places
                    // the sphere center (a pending mask you size + Approve). If
                    // a mask is already pending, a click re-places its center.
                    // This overlay tracks the fitted image frame, the same space
                    // the overlays draw in, so the click maps to normalized.
                    .overlay {
                        if seedingAllowed {
                            GeometryReader { geo in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                                        guard geo.size.width > 0, geo.size.height > 0 else { return }
                                        let nx = Double(v.location.x / geo.size.width)
                                        let ny = Double(v.location.y / geo.size.height)
                                        if node.pendingSeed != nil {
                                            node.moveSeedCenter(normX: nx, normY: ny)
                                        } else {
                                            array.seedSphere(node, normX: nx, normY: ny)
                                        }
                                    })
                            }
                        }
                    }
            } else {
                Text(stream.isStreaming ? "waiting for frames…" : "no stream")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink3)
            }

            if manualActive && array.manualPhase == .trimming && !manualPaused {
                BigIREReadouts(info: node.manualMatch)
            }

            if manualPaused {
                ZStack {
                    Color.black.opacity(0.28)
                    ManualRecoveryText(
                        size: 32,
                        label: manualWaking ? "WAKING STREAM" : "HOLD - RECOVERING"
                    )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: Theme.radius)
                            .fill(Color.black.opacity(0.76)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                            .stroke(Theme.warn.opacity(0.72), lineWidth: 1.5))
                }
                .allowsHitTesting(false)
            }

            VStack {
                // Header strip
                HStack(spacing: 10) {
                    StatusDot(level: node.connected ? .ok : .off)
                    Text(node.status.displayID.isEmpty ? node.ip : node.status.displayID)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(node.ip)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink3)
                    Text("T \(RCP2.stopLabel(node.status.apertureCur))")
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                    if !manualPaused, let ire = node.sphere.heroIRE {
                        Text(String(format: "%.1f IRE", ire))
                            .font(Theme.mono(13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    // During a calibrate run the sequence is driven, not
                    // hand-advanced: showing a Proceed or Next Camera control
                    // here would let the operator fight the run loop.
                    if !manualActive
                        || (array.manualPhase == .trimming && !array.calibrateMode) {
                        if manualActive && array.effectiveAdvanceMode == .operatorProceed {
                            Button {
                                array.proceedManualMatch()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(array.manualProceedTitle(from: node))
                                        .font(.system(size: 12, weight: .bold))
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                }
                            }
                            .buttonStyle(DarkButtonStyle(prominent: true))
                            .disabled(manualPaused || !array.canProceedManualMatch(from: node))
                            .help("Available after this camera holds inside the match band for the full certification time.")
                        } else {
                            Button { array.fullscreenStep(-1) } label: {
                                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            }
                            .buttonStyle(DarkButtonStyle())
                            .help("Previous camera")
                            Button { array.fullscreenStep(1) } label: {
                                HStack(spacing: 4) {
                                    Text("Next Camera").font(.system(size: 12, weight: .semibold))
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                                }
                            }
                            .buttonStyle(DarkButtonStyle(prominent: true))
                            .help("Jump to the next camera (ID order) without minimizing")
                        }
                    }
                    // Grouped to keep this HStack under the ten-child
                    // ViewBuilder limit, which it was already close to.
                    Group {
                        // Start the run without dropping out of fullscreen.
                        if array.calibrateMode, !manualActive,
                           !array.calibrationRunActive {
                            Button("Start Run Here") {
                                array.beginCalibrationRun(startingAt: node)
                            }
                            .buttonStyle(DarkButtonStyle(prominent: true))
                            .disabled(!array.canStartRunHere(node))
                            .help("Begin the calibration run at this camera and continue in IP order. Each body is seeded when the run reaches it.")
                        }
                        // The run's own controls, in reach of the hand on the ring.
                        if array.calibrateMode, array.calibrationRunActive,
                           array.manualPhase == .trimming
                            || array.calibrationAwaitingSeed {
                            Button("Skip") { array.skipCalibrationCamera() }
                                .buttonStyle(DarkButtonStyle())
                                .help("Leave this body un-calibrated and move the run to the next camera.")
                            Button("Stop Run") { array.stopCalibrationRun() }
                                .buttonStyle(DarkButtonStyle(destructive: true))
                                .help("Stop after this camera. Its output preset is still restored.")
                        }
                        if manualActive,
                           (array.manualPhase == .preparing
                            || array.manualPhase == .trimming) {
                            Button("Abort & Restore") {
                                array.abortManualMatch()
                            }
                            .buttonStyle(DarkButtonStyle(destructive: true))
                        }
                    }
                    Button {
                        array.fullScreenNodeID = nil
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(
                        manualActive
                            && (array.manualPhase == .preparing
                                || (array.manualPhase == .trimming
                                    && array.effectiveAdvanceMode == .operatorProceed
                                    // Calibrate forces operatorProceed to stop
                                    // the auto-handoff, but with a single body
                                    // there is no gate to bypass — trapping the
                                    // operator in fullscreen would be pointless.
                                    && !array.calibrateMode))
                    )
                    .help("Exit full screen (Esc)")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(LinearGradient(colors: [Color.black.opacity(0.7), .clear],
                                           startPoint: .top, endPoint: .bottom))
                if seedingAllowed, node.pendingSeed == nil {
                    Text(node.sphere.seeded ? "Sphere locked — click to re-place, or Re-detect to clear"
                                            : "Click the sphere center to place a mask")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, 2)
                }
                Spacer()
                if seedingAllowed, let seed = node.pendingSeed {
                    SeedControlBar(node: node, seed: seed)
                }
            }
        }
        // Exit via Esc or the collapse button — the image itself is the
        // click-to-seed surface, so no tap-to-exit here.
        .onExitCommand {
            if !manualActive
                || (array.manualPhase != .preparing
                    && !(array.manualPhase == .trimming
                        && array.effectiveAdvanceMode == .operatorProceed
                        // Single-body calibrate has no handoff gate to bypass.
                        && !array.calibrateMode)) {
                array.fullScreenNodeID = nil
            }
        }
    }
}

// MARK: - Sphere-centric trim dial (fullscreen manual mode)
//
// The dial lives AROUND the detected sphere, so the target stays fully
// visible while trimming — designed for a laptop mirrored to an on-set
// monitor, read from the camera position:
//   · an amber arc winds out from 12 o'clock in the DIAL DIRECTION —
//     clockwise/right = OPEN, counter-clockwise/left = CLOSE; its length is
//     the remaining correction (±1 stop full scale). Trim the ring and the
//     arc slowly winds back to zero.
//   · a green notch at 12 o'clock is the capture band, sized by the REAL
//     session tolerance; inside it the dial turns teal and the notch fills
//     as the hold-to-confirm progresses; solid green ring = matched.
//   · chevrons march just ahead of the arc tip, pointing the way to turn.
// Numerals live at the screen edges (BigIREReadouts) — nothing sits on
// the sphere.

struct IrisDialOverlay: View {
    let sphere: SphereState
    let info: ManualMatchInfo

    static let fullScaleStops = 1.0
    static let maxSweepDeg = 130.0

    private var cueColor: Color { ManualCueStyle.color(info.phase) }
    private var opening: Bool { (info.correctionStops ?? 0) > 0 }

    var body: some View {
        GeometryReader { geo in
            if sphere.hasROI {
                let cx = sphere.cx * geo.size.width
                let cy = sphere.cy * geo.size.height
                let sphereR = sphere.r * geo.size.width
                // Well clear of the sphere: the dial is instrumentation, the
                // sphere is the subject — they should never read as one shape.
                let ringR = min(max(sphereR * 2.4, 120),
                                min(geo.size.width, geo.size.height) * 0.46)
                dial(radius: ringR, sphereR: sphereR)
                    .position(x: cx, y: cy)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dial(radius: CGFloat, sphereR: CGFloat) -> some View {
        // Read-from-12-feet geometry: the ring is a signal lamp first and an
        // instrument second — the assistant has hands on the camera and the
        // monitor across the volume. Thick main track, tick scale outside,
        // segmented idle ring hugging the sphere inside.
        let ringW = max(20, radius * 0.15)
        let tickR = radius + ringW * 1.15
        let corr = info.correctionStops ?? 0
        let sweepFrac = min(1, abs(corr) / Self.fullScaleStops) * Self.maxSweepDeg / 360.0
        let notchHalfFrac = min(0.5, (info.toleranceStops / Self.fullScaleStops))
            * Self.maxSweepDeg / 360.0
        let matched = info.phase == .matched
        let holding = info.phase == .hold
        let trackFrac = Self.maxSweepDeg * 2 / 360.0

        ZStack {
            // Faint thick track — the visible ±1-stop scale
            Circle()
                .trim(from: 0, to: trackFrac)
                .stroke(Color.white.opacity(0.13),
                        style: StrokeStyle(lineWidth: ringW, lineCap: .round))
                .rotationEffect(.degrees(-90 - Self.maxSweepDeg))

            // Tick scale: minors every 1/16 stop, majors each 1/4 stop
            ForEach(-16...16, id: \.self) { q in
                let major = q % 4 == 0
                let angDeg = -90.0 + Double(q) / 16.0 * Self.maxSweepDeg
                Rectangle()
                    .fill(Color.white.opacity(major ? 0.55 : 0.22))
                    .frame(width: major ? 2.5 : 1, height: major ? 14 : 7)
                    .offset(y: -(tickR + (major ? 7 : 3.5)))
                    .rotationEffect(.degrees(angDeg + 90))
            }
            // Stop labels at the scale ends and halves
            ForEach([-1.0, -0.5, 0.5, 1.0], id: \.self) { stops in
                let ang = (-90.0 + stops * Self.maxSweepDeg) * .pi / 180
                Text(abs(stops) == 1 ? "1.0" : ".5")
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .offset(x: (tickR + 30) * cos(ang), y: (tickR + 30) * sin(ang))
            }

            // Segmented inner ring hugging the sphere — slow idle rotation
            dialInnerRing(radius: min(sphereR * 1.22, radius - ringW), matched: matched)

            // Capture notch at 12 o'clock (± tolerance)
            Circle()
                .trim(from: 0, to: notchHalfFrac * 2)
                .stroke(Theme.good.opacity(matched ? 1 : 0.65),
                        style: StrokeStyle(lineWidth: ringW, lineCap: .round))
                .rotationEffect(.degrees(-90 - notchHalfFrac * 360))
                .shadow(color: Theme.good.opacity(0.5), radius: 8)

            // Hold-to-confirm: the notch fills with teal as stability builds
            if holding || matched {
                Circle()
                    .trim(from: 0, to: notchHalfFrac * 2 * (matched ? 1 : min(1, info.stability)))
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: ringW, lineCap: .round))
                    .rotationEffect(.degrees(-90 - notchHalfFrac * 360))
                    .shadow(color: Theme.accent.opacity(0.7), radius: 9)
                    .animation(.linear(duration: 0.2), value: info.stability)
            }

            // Matched: the whole ring lights green
            if matched {
                Circle()
                    .stroke(Theme.good.opacity(0.92), lineWidth: ringW * 0.55)
                    .shadow(color: Theme.good.opacity(0.6), radius: 12)
            }

            // Correction arc — thick, glowing, winds out in the dial
            // direction and back to zero as the operator trims.
            if info.phase == .open || info.phase == .close {
                // Glow underlay
                Circle()
                    .trim(from: 0, to: sweepFrac)
                    .stroke(cueColor.opacity(0.35),
                            style: StrokeStyle(lineWidth: ringW * 1.9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: opening ? 1 : -1, y: 1)
                    .blur(radius: 6)
                // Core
                Circle()
                    .trim(from: 0, to: sweepFrac)
                    .stroke(cueColor,
                            style: StrokeStyle(lineWidth: ringW, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: opening ? 1 : -1, y: 1)
                    .animation(.easeOut(duration: 0.45), value: sweepFrac)
                // Bright tip cap
                dialTipCap(radius: radius, sweepFrac: sweepFrac, ringW: ringW)

                dialChevrons(radius: radius, sweepFrac: sweepFrac, ringW: ringW)
                dialDeltaChip(radius: radius, sweepFrac: sweepFrac, ringW: ringW, corr: corr)
            }

            // Phase word above the tick scale — readable across the volume
            Text(info.phase.rawValue)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .tracking(3.5)
                .foregroundStyle(cueColor)
                .shadow(color: .black.opacity(0.85), radius: 3)
                .offset(y: -tickR - 46)
        }
        .frame(width: radius * 2, height: radius * 2)
    }

    private func dialTipCap(radius: CGFloat, sweepFrac: Double, ringW: CGFloat) -> some View {
        let dir: Double = opening ? 1 : -1
        let ang = (-90.0 + dir * sweepFrac * 360.0) * .pi / 180
        return Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: ringW * 1.2, height: ringW * 1.2)
            .shadow(color: cueColor, radius: 6)
            .offset(x: radius * cos(ang), y: radius * sin(ang))
            .animation(.easeOut(duration: 0.45), value: sweepFrac)
    }

    private func dialDeltaChip(radius: CGFloat, sweepFrac: Double, ringW: CGFloat, corr: Double) -> some View {
        let dir: Double = opening ? 1 : -1
        let ang = (-90.0 + dir * (sweepFrac * 360.0 + 46)) * .pi / 180
        let chipR = radius + ringW * 2.6
        return Text(String(format: "Δ %.2f", abs(corr)))
            .font(Theme.mono(16, weight: .bold))
            .foregroundStyle(cueColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(cueColor.opacity(0.85), lineWidth: 1.5))
            .offset(x: chipR * cos(ang), y: chipR * sin(ang))
            .animation(.easeOut(duration: 0.45), value: sweepFrac)
    }

    /// Segmented ring hugging the sphere with a slow JARVIS idle spin.
    private func dialInnerRing(radius: CGFloat, matched: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let spin = (t * 8).truncatingRemainder(dividingBy: 360)
            let circumference = 2 * .pi * radius
            let seg = circumference / 14
            Circle()
                .stroke((matched ? Theme.good : cueColor).opacity(0.35),
                        style: StrokeStyle(lineWidth: 3, dash: [seg * 0.55, seg * 0.45]))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(spin))
        }
    }

    /// Chevrons marching just ahead of the arc tip, tangent to the ring,
    /// pointing the direction to turn the iris ring.
    private func dialChevrons(radius: CGFloat, sweepFrac: Double, ringW: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t * 2.2).truncatingRemainder(dividingBy: 1.0)
            let dir: Double = opening ? 1 : -1
            let tipDeg = -90.0 + dir * sweepFrac * 360.0
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let angDeg = tipDeg + dir * (14.0 + Double(i) * 13.0)
                    let ang = angDeg * .pi / 180
                    let local = (phase - Double(i) * 0.22).truncatingRemainder(dividingBy: 1.0)
                    let pulse = local >= 0 && local < 0.45 ? 1.0 : 0.3
                    Image(systemName: "chevron.right")
                        .font(.system(size: max(13, ringW * 1.6), weight: .heavy))
                        .foregroundStyle(cueColor.opacity(pulse))
                        .rotationEffect(.degrees(angDeg + (opening ? 90 : -90)))
                        .offset(x: radius * cos(ang), y: radius * sin(ang))
                }
            }
        }
    }
}

/// Edge-anchored numerals for across-the-room reading: CURRENT on the left,
/// TARGET on the right — large, clear of the sphere and the dial.
struct BigIREReadouts: View {
    let info: ManualMatchInfo

    private var cueColor: Color { ManualCueStyle.color(info.phase) }
    private var trimming: Bool { info.phase == .open || info.phase == .close }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(2.5)
                    .foregroundStyle(Theme.ink3)
                Text(info.currentIRE.map { String(format: "%.1f", $0) } ?? "——")
                    .font(Theme.mono(76, weight: .bold))
                    .foregroundStyle(cueColor)
                    .contentTransition(.numericText())
                if let correction = info.correctionStops, trimming {
                    Text(String(format: "%@ %.2f st to go",
                                correction > 0 ? "open" : "close", abs(correction)))
                        .font(Theme.mono(15, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                } else if info.phase == .hold {
                    Text("hold steady…")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TARGET")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(2.5)
                    .foregroundStyle(Theme.ink3)
                Text(info.targetIRE.map { String(format: "%.0f", $0) } ?? "——")
                    .font(Theme.mono(76, weight: .bold))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.horizontal, 44)
        .shadow(color: .black.opacity(0.85), radius: 6)
        .allowsHitTesting(false)
    }
}

/// Detected-sphere circle in normalized frame coordinates over the live image.
/// If this renders vertically mirrored on the bench, flip the y term here AND
/// the row order in PixelBuffer.from (they must agree).
struct SphereOverlay: View {
    let sphere: SphereState

    var body: some View {
        GeometryReader { geo in
            if sphere.hasROI {
                let cx = sphere.cx * geo.size.width
                let cy = sphere.cy * geo.size.height
                let d = sphere.r * 2 * geo.size.width
                // Center sample point — the hero-IRE probe region (0.24r disk).
                let sd = sphere.r * 0.24 * 2 * geo.size.width
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: d, height: d)
                    .position(x: cx, y: cy)
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: max(sd, 5), height: max(sd, 5))
                    .position(x: cx, y: cy)
            }
        }
        .allowsHitTesting(false)
    }

    var color: Color {
        switch sphere.phase {
        case .locked: return Theme.good
        case .coasting: return Theme.warn
        case .candidate: return Theme.accent
        case .searching: return .clear
        }
    }
}

/// Pending (un-approved) sphere mask: dashed circle, the center sample-point
/// disk, and a center dot — drawn in the same normalized space as SphereOverlay.
struct PendingSeedOverlay: View {
    let seed: PendingSeed

    var body: some View {
        GeometryReader { geo in
            let cx = seed.cx * geo.size.width
            let cy = seed.cy * geo.size.height
            let d = seed.r * 2 * geo.size.width
            let sd = seed.r * 0.24 * 2 * geo.size.width
            Circle()
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: d, height: d)
                .position(x: cx, y: cy)
            Circle()
                .fill(Theme.accent.opacity(0.45))
                .frame(width: max(sd, 6), height: max(sd, 6))
                .position(x: cx, y: cy)
            Circle()
                .fill(Theme.accent)
                .frame(width: 4, height: 4)
                .position(x: cx, y: cy)
        }
        .allowsHitTesting(false)
    }
}

/// Bottom bar shown while sizing a pending sphere mask in full screen.
struct SeedControlBar: View {
    @EnvironmentObject var array: ArrayController
    @ObservedObject var node: CameraNode
    let seed: PendingSeed

    var body: some View {
        HStack(spacing: 12) {
            Text("Mask size")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink3)
            Slider(value: Binding(get: { node.pendingSeed?.r ?? seed.r },
                                  set: { node.setSeedRadius($0) }),
                   in: 0.02...0.32)
                .frame(maxWidth: 320)
            Text(String(format: "r %.0f%%", seed.r * 100))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .frame(width: 52, alignment: .leading)
            Button("Approve") { array.approveSeed(node) }
                .buttonStyle(DarkButtonStyle(prominent: true))
            Button("Cancel") { array.cancelSeed(node) }
                .buttonStyle(DarkButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LinearGradient(colors: [.clear, Color.black.opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Array actions panel

struct ArrayActionsPanel: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Array", count: "\(array.nodes.count)")
            HStack(spacing: 6) {
                Button("Connect All") { array.connectAll() }
                    .buttonStyle(DarkButtonStyle(prominent: true))
                Button("Stream All") { array.streamAll() }
                    .buttonStyle(DarkButtonStyle())
                Button("Disconnect All") { array.disconnectAll() }
                    .buttonStyle(DarkButtonStyle(destructive: true))
            }
            .disabled(array.manualSessionActive)

            // Stays enabled during a match: recovers timed-out livestreams in
            // place without aborting or losing seeds.
            HStack(spacing: 8) {
                Button("Reconnect Streams") { array.reconnectStreams() }
                    .buttonStyle(DarkButtonStyle())
                    .help("Revive dropped sessions and restart timed-out livestreams. Safe mid-match — keeps seeds, masks, and the Log3G10 swap.")
                Toggle(isOn: $array.autoRecoverStreams) {
                    Text("Auto-recover")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .help("Automatically restart any livestream that drops or stalls (per-camera backoff). Leaves seeds and the transform untouched.")
            }

            Toggle(isOn: $array.logSphereDiagnostics) {
                Text("Log sphere detector diagnostics (Hough + gate ladder, unseeded cameras)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.ink2)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .help("For cameras you leave un-seeded, logs why auto-detect did or didn't latch: candidate count, support, and each gate's value. Throttled to ~1.5s per camera.")
            Button("Prepare — e-iris gate + AE check + subscribe") { array.prepareAll() }
                .buttonStyle(DarkButtonStyle())
                .disabled(array.manualSessionActive)
                .help("Per body: APERTURE_CONTROL gate, AE warning, valid stop list, APERTURE subscription for the settle detector. Identifies which bodies are e-iris — required before Hybrid can push them. One deliberate operator action — rule 11.")
            if array.usesOperatorGuidance {
                Text("Hybrid and Calibrate drive APERTURE only on e-iris bodies you explicitly push to target; manual glass is hand-guided with OPEN / CLOSE and never receives a command.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Livestream quality — Q100 default; every push is read-back
            // verified per body (a silent Q25 flattens sphere shading).
            HStack(spacing: 6) {
                Text("Livestream Q")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                Picker("Quality", selection: $array.arrayQuality) {
                    ForEach(array.commonLivestreamQualityOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)
                .disabled(array.qualityControlsLocked || array.qualityVerificationInProgress)
                Button("Apply") { array.setQualityAll() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(array.qualityControlsLocked || array.qualityVerificationInProgress || array.nodes.isEmpty)
            }
            Text(array.arrayQualityStatus)
                .font(.system(size: 10))
                .foregroundStyle(array.arrayActualQuality == nil ? Theme.warn : Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Text("RCP2 factors are Q25/Q50/Q75/Q100. The app sends the exact value, reads each camera back, and blocks measurement unless every actual value is identical.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            // Latency options (apply to both Electronic and Manual Assist).
            Toggle(isOn: $array.dropStaleFrames) {
                Text("Freshest frame — drop stale livestream frames")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.ink2)
            }
            .toggleStyle(.switch).tint(Theme.accent)
            .help("Decode only the newest frame when frames back up: lower display latency and less main-thread load. No effect on the IRE measurement.")

            Text("During measurement, every participant is held at one identical camera-reported quality. Fullscreen focus changes analysis cadence only; it never changes JPEG quality.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelCard()
    }
}

// MARK: - Match workflow selection

struct MatchWorkflowPanel: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Match Workflow", count: array.matchWorkflow.rawValue)
            Picker("Workflow", selection: $array.matchWorkflow) {
                ForEach(ArrayController.MatchWorkflow.allCases) { workflow in
                    Text(workflow.rawValue).tag(workflow)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(array.workflowBusy)

            Text(workflowExplainer)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Button("Seed all solved") { array.seedAllSolved() }
                .buttonStyle(DarkButtonStyle())
                .disabled(array.manualSessionActive || array.nodes.isEmpty)
                .help("Lock every camera's current auto-detected sphere as a durable operator seed so the solve survives a workflow switch and the Log3G10 swap. Run this before leaving Electronic so you never lose the solve on the way into Hybrid.")
        }
        .panelCard()
    }

    private var workflowExplainer: String {
        switch array.matchWorkflow {
        case .electronic:
            return "Electronic drives every supported iris over RCP2 automatically and verifies settle after each move — best for an all-motorized array."
        case .hybrid:
            return "Hybrid captures one shared target, hand-guides manual glass with live OPEN / CLOSE, and lets you push any e-iris body to target on command. Mixed rigs welcome."
        case .calibrate:
            return "Calibrate runs ONE body at a time against an integrating sphere. Establish the target on the first camera, pin it, and every camera after it trims to that same IRE — manual glass by hand, e-iris on command."
        }
    }
}

// MARK: - Manual Assist panel

struct ManualAssistPanel: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            GroupHeader(title: "Hybrid",
                        count: manualCount,
                        warn: array.manualSessionActive,
                        danger: array.manualPhase == .failed)

            Text("Captures one shared target from stable sphere measurements, temporarily normalizes mirrored outputs to Log3G10, and restores their saved presets on Finish or Abort. Manual glass gets OPEN / CLOSE guidance; e-iris bodies can be pushed to target on command.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Monitoring", selection: $array.manualTransform) {
                ForEach(ArrayController.ManualTransform.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(array.manualSessionActive)
            Text(array.manualTransform.isLog3G10
                 ? "Swaps the chosen output's Look (LCD or SDI) to Log3G10 for the match (18% gray = 33.3 IRE); restores it on Finish/Abort. Pick the output your livestream mirrors."
                 : "Display/IPP2 stop math is not yet bench-calibrated, so capture is blocked in this mode. Select Log3G10 for exposure-accurate guidance.")
                .font(.system(size: 10))
                .foregroundStyle(array.manualTransform.isLog3G10 ? Theme.ink3 : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Target", selection: $array.manualTargetMode) {
                ForEach(ArrayController.ManualTargetMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(array.manualSessionActive)

            if array.manualTargetMode == .custom {
                HStack(spacing: 8) {
                    Text("Target IRE")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                    TextField("33.3", text: $array.manualTargetText)
                        .darkField()
                        .frame(width: 78)
                }
                .disabled(array.manualSessionActive)
            }

            manualConfigRow("Tolerance", String(format: "±%.2fst", array.manualToleranceStops)) {
                Slider(value: $array.manualToleranceStops, in: 0.02...0.30, step: 0.01)
            }
            .disabled(array.manualSessionActive)
            HStack {
                Text("Stable hold")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Text(String(format: "%.1fs fixed", array.manualHoldSeconds))
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }

            HStack {
                Text("After match")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                Spacer()
            }
            Picker("Advance mode", selection: $array.manualAdvanceMode) {
                ForEach(ArrayController.ManualAdvanceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(array.manualSessionActive)
            Text(array.manualAdvanceMode == .automatic
                 ? "After the stable hold completes, fullscreen advances to the next camera automatically."
                 : "After the stable hold completes, a gated Proceed button lets the operator advance. R3DIris never changes cameras on its own.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                switch array.manualPhase {
                case .preparing:
                    Button("Abort & Restore") { array.abortManualMatch() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                case .trimming:
                    // Report is always available while matching — even if the
                    // array never reaches an all-green "complete" (e.g. one
                    // camera intentionally at a different exposure).
                    Button("Report & Restore") { array.finishManualMatchReport() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                    Button("Abort & Restore") { array.abortManualMatch() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                case .complete:
                    Button("Report & Restore") { array.finishManualMatchReport() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                    Button("Restore only") { array.finishManualMatch() }
                        .buttonStyle(DarkButtonStyle())
                    Button("Abort") { array.abortManualMatch() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                case .restoring:
                    ProgressView().controlSize(.small)
                    Text("Restoring…")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                case .failed where array.manualRestorePending:
                    Button("Retry Output Restore") { array.retryManualRestore() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                    Text("\(array.manualChangedOutputCount) pending")
                        .font(Theme.mono(9.5, weight: .bold))
                        .foregroundStyle(Theme.danger)
                case .idle, .finished, .failed:
                    Button("Capture Target & Start") { array.startManualMatch() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(
                            !array.manualTransform.isLog3G10
                                || array.qualityVerificationInProgress
                                || (array.manualTargetMode == .custom
                                    && array.manualCustomTargetIRE == nil)
                        )
                }
                Spacer()
                Text(array.manualPhase.rawValue.uppercased())
                    .font(Theme.mono(9.5, weight: .bold))
                    .foregroundStyle(phaseColor)
            }

            Text(array.manualStatus)
                .font(.system(size: 10.5, weight: array.manualCommonDriftStops == nil ? .regular : .semibold))
                .foregroundStyle(array.manualCommonDriftStops == nil ? Theme.ink2 : Theme.danger)
                .fixedSize(horizontal: false, vertical: true)

            if array.manualTargetIRE != nil {
                HStack(spacing: 6) {
                    manualStat("TARGET", array.manualTargetIRE.map { String(format: "%.0f IRE", $0) } ?? "—")
                    manualStat("MATCHED", "\(array.manualMatchedCount)/\(array.manualParticipantCount)")
                    manualStat("LATEST SPREAD", array.manualArraySpreadStops.map { String(format: "%.2fst", $0) } ?? "—")
                }
            }

            // Array-wide operator-approved push — only shown when the session owns
            // at least one e-iris participant. Disabled when they're all in
            // tolerance (nothing to send).
            if array.manualSessionActive, array.manualParticipants.contains(where: { $0.eIris }) {
                Button(array.hybridPushableCount > 0
                       ? "Push \(array.hybridPushableCount) e-iris → target"
                       : "e-iris in tolerance") {
                    array.pushAllHybridApertures()
                }
                .buttonStyle(DarkButtonStyle(prominent: array.hybridPushableCount > 0))
                .disabled(array.hybridPushableCount == 0)
                .help("Push every out-of-tolerance e-iris body one step toward the shared target. Re-press after they settle to converge; manual glass is never touched.")
            }

            if let drift = array.manualCommonDriftStops {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(String(format: "GLOBAL DRIFT %+.2f ST — PAUSE", drift))
                        .font(Theme.mono(10.5, weight: .bold))
                }
                .foregroundStyle(Theme.danger)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.dangerBG))
            }

            if let active = array.fullScreenNode,
               array.isManualParticipant(active) {
                ManualTrimFocus(node: active)
            }

            if !array.manualParticipants.isEmpty {
                VStack(spacing: 3) {
                    ForEach(array.manualParticipants) { node in
                        ManualCameraRow(node: node)
                    }
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2))
            }
        }
        .panelCard()
    }

    var manualCount: String {
        array.manualParticipantCount == 0
            ? array.manualPhase.rawValue
            : "\(array.manualMatchedCount)/\(array.manualParticipantCount)"
    }

    var phaseColor: Color {
        switch array.manualPhase {
        case .complete, .finished: return Theme.good
        case .failed: return Theme.danger
        case .preparing, .restoring: return Theme.warn
        case .trimming: return Theme.accent
        case .idle: return Theme.idle
        }
    }

    @ViewBuilder
    func manualConfigRow<S: View>(_ label: String, _ value: String,
                                  @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink2)
                .frame(width: 72, alignment: .leading)
            slider()
                .controlSize(.small)
                .disabled(array.manualSessionActive)
            Text(value)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink)
                .frame(width: 62, alignment: .trailing)
        }
    }

    func manualStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink3)
            Text(value)
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2))
    }
}

// MARK: - Calibrate panel (one body at a time)

struct CalibrationPanel: View {
    @EnvironmentObject var array: ArrayController
    @State private var confirmingClearRoll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            GroupHeader(title: "Calibrate",
                        count: headerCount,
                        warn: array.manualSessionActive,
                        danger: array.manualPhase == .failed)

            Text("One press walks every connected camera in IP order. Per body: solve the sphere, dial to target, hold \(String(format: "%.0f", array.manualHoldSeconds))s, re-verify, restore the output — then it moves on. The next \(ArrayController.calibrationPrewarmDepth) cameras are brought up behind it, so you are only ever waiting on your own solve.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            // Grouped: a ViewBuilder body takes at most ten children, and this
            // panel has more sections than that.
            Group {
                monitoringPicker
                targetSection
                toleranceRow
                sessionControls
            }

            Text(array.manualStatus)
                .font(.system(size: 10.5))
                .foregroundStyle(array.manualPhase == .failed ? Theme.danger : Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if let target = array.manualTargetIRE {
                HStack(spacing: 6) {
                    stat("TARGET", String(format: "%.1f IRE", target))
                    stat("DELTA", focusedDeltaText)
                    stat("CORRECTION", focusedCorrectionText)
                }
            }

            eIrisPush
            trimFocus
            rollSection
        }
        .panelCard()
    }

    // MARK: Monitoring

    private var monitoringPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Monitoring", selection: $array.manualTransform) {
                ForEach(ArrayController.ManualTransform.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(array.manualSessionActive)

            Text(array.manualTransform.isLog3G10
                 ? "Swaps this camera's mirrored output to Log3G10 for the session and restores its saved preset on finish."
                 : "Display/IPP2 stop math is not yet bench-calibrated, so calibration is blocked in this mode. Select Log3G10.")
                .font(.system(size: 10))
                .foregroundStyle(array.manualTransform.isLog3G10 ? Theme.ink3 : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Target source", selection: $array.calibrationTargetSource) {
                ForEach(ArrayController.CalibrationTargetSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(array.manualSessionActive)

            Text(targetSourceExplainer)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            if array.calibrationTargetSource == .gray18 {
                HStack(spacing: 8) {
                    Text("Anchor")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                    Text(String(format: "%.1f IRE", array.manualTransform.isLog3G10
                                ? Log3G10.grayAnchorIRE : ArrayController.ipp2GrayAnchorIRE))
                        .font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            if array.calibrationTargetSource == .custom {
                HStack(spacing: 8) {
                    Text("Target IRE")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                    TextField("33.3", text: $array.calibrationTargetText)
                        .darkField()
                        .frame(width: 78)
                }
                .disabled(array.manualSessionActive)
            }

            if let pin = array.calibrationPin,
               !array.calibrationTargetSource.isAbsolute {
                HStack(spacing: 7) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "PINNED %.2f IRE · %@", pin.ire, pin.transform))
                            .font(Theme.mono(10.5, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text("from \(pin.sourceCameraID.isEmpty ? "—" : pin.sourceCameraID) · \(Self.stamp.string(from: pin.capturedAt))")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    if array.canPinCalibrationTarget, !isEstablishCamera {
                        Button("Re-pin") { array.pinCalibrationTarget() }
                            .buttonStyle(DarkButtonStyle())
                            .help("Replace the stored reference with this session's current target.")
                    }
                    Button("Clear") { array.clearCalibrationPin() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                        .disabled(array.manualSessionActive)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.accentBG))
            }

            if let failure = array.calibrationTargetFailure(), !array.manualSessionActive {
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var targetSourceExplainer: String {
        switch array.calibrationTargetSource {
        case .gray18:
            return String(format: "Absolute anchor: 18%% gray sits at %.1f IRE in %@. Every camera — including the first — is hand-dialed to it.",
                          array.manualTransform.isLog3G10 ? Log3G10.grayAnchorIRE : ArrayController.ipp2GrayAnchorIRE,
                          array.manualTransform.isLog3G10 ? "Log3G10" : "IPP2")
        case .establish:
            return "The first camera is NOT dialed: whatever it reads becomes the target and is pinned immediately. Every camera after it is dialed to match that reading."
        case .pinned:
            return "Every camera is dialed to match the stored reading. Nothing to type, and the number cannot drift between bodies or across restarts."
        case .custom:
            return "Absolute: trim every camera to the IRE you enter. Nothing is pinned — the number did not come from a reading."
        }
    }

    // MARK: Tolerance

    private var toleranceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Tolerance")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 72, alignment: .leading)
                Slider(value: $array.manualToleranceStops, in: 0.02...0.30, step: 0.01)
                    .controlSize(.small)
                    .disabled(array.manualSessionActive)
                Text(String(format: "±%.2fst", array.manualToleranceStops))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 62, alignment: .trailing)
            }
            HStack {
                Text("Stable hold")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Text(String(format: "%.1fs fixed", array.manualHoldSeconds))
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    // MARK: Session controls

    @ViewBuilder
    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if array.calibrationRunActive {
                runProgress
                activeRunControls
            } else {
                idleRunControls
            }
            HStack {
                Spacer()
                Text(runStateLabel)
                    .font(Theme.mono(9.5, weight: .bold))
                    .foregroundStyle(runStateHighlighted ? Theme.accent : phaseColor)
            }
        }
    }

    /// Where the run is, and what it will visit next.
    private var runProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(array.calibrationCamera.map { "NOW: \($0.displayName)" } ?? "NOW: —")
                    .font(Theme.mono(10.5, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(min(array.calibrationQueueIndex + 1, array.calibrationRunTotal))/\(array.calibrationRunTotal)")
                    .font(Theme.mono(10.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            ProgressView(
                value: Double(array.calibrationQueueIndex),
                total: Double(max(1, array.calibrationRunTotal))
            )
            .controlSize(.small)
            .tint(Theme.accent)
            if let next = nextInQueue {
                HStack(spacing: 5) {
                    Text("next: \(next.displayName) · \(next.ip)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink3)
                    if array.calibrationPrewarmedIDs.contains(next.id) {
                        Text("READY")
                            .font(Theme.mono(8, weight: .bold))
                            .foregroundStyle(Theme.good)
                    }
                    Spacer()
                    Text("\(array.calibrationPrewarmedIDs.count) warmed")
                        .font(Theme.mono(8.5))
                        .foregroundStyle(Theme.ink3)
                }
            } else {
                Text("last camera in the run")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.accentBG))
    }

    @ViewBuilder
    private var activeRunControls: some View {
        if array.calibrationAwaitingSeed {
            Text("Click the sphere centre in fullscreen, size the mask, and Approve. The run is holding here.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            // Optional, and only on the establish camera. That camera is NOT
            // dialed — its reading is already the target — but if it happened to
            // be at a silly aperture this re-points the run without restarting it.
            if array.canSetCalibrationTargetFromLive, isEstablishCamera,
               array.calibrationTargetSource == .establish
                || array.calibrationTargetSource == .pinned {
                Button("Re-target from Live") { array.setCalibrationTargetFromLive() }
                    .buttonStyle(DarkButtonStyle())
                    .help("Take this camera's current reading as the run's target instead. Re-pins it and restarts the hold.")
            }
            if array.manualPhase == .restoring {
                ProgressView().controlSize(.small)
                Text("Restoring…")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.ink2)
            } else {
                Button("Skip Camera") { array.skipCalibrationCamera() }
                    .buttonStyle(DarkButtonStyle())
                    .help("Leave this body un-calibrated and advance the run.")
            }
            Button("Stop Run") { array.stopCalibrationRun() }
                .buttonStyle(DarkButtonStyle(destructive: true))
                .help("Stop after this camera. Its saved output preset is still restored.")
            Spacer()
        }
    }

    @ViewBuilder
    private var idleRunControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if array.manualRestorePending {
                HStack(spacing: 8) {
                    Button("Retry Output Restore") { array.retryManualRestore() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                    Text("\(array.manualChangedOutputCount) pending")
                        .font(Theme.mono(9.5, weight: .bold))
                        .foregroundStyle(Theme.danger)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Button("Begin Calibration Run") { array.beginCalibrationRun() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(!array.canBeginCalibrationRun)
                        .help("Walk every connected camera in IP order. Each body is seeded, trimmed, held, re-verified and restored before the run moves to the next.")
                    Text("\(array.calibrationRunOrder.count) connected")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                }
                if !array.calibrationRunOrder.isEmpty {
                    Text("order: " + array.calibrationRunOrder.prefix(4)
                            .map(\.displayName).joined(separator: " → ")
                         + (array.calibrationRunOrder.count > 4 ? " → …" : ""))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The run's first camera — where the number for the whole set is chosen.
    /// Kept available for the WHOLE of that camera's session, not just while the
    /// commit gate is armed, so the operator can still re-point the target after
    /// committing but before it certifies.
    private var isEstablishCamera: Bool {
        array.calibrationRunActive && array.calibrationQueueIndex == 0
    }

    private var runStateLabel: String {
        if array.calibrationAwaitingSeed { return "AWAITING SEED" }
        if array.calibrationReverifying { return "RE-VERIFYING" }
        return array.manualPhase.rawValue.uppercased()
    }

    private var runStateHighlighted: Bool {
        array.calibrationAwaitingSeed || array.calibrationReverifying
    }

    private var nextInQueue: CameraNode? {
        let nodes = array.calibrationQueueNodes
        let next = array.calibrationQueueIndex + 1
        return next < nodes.count ? nodes[next] : nil
    }

    // MARK: e-iris

    @ViewBuilder
    private var eIrisPush: some View {
        if array.manualSessionActive,
           array.manualParticipants.contains(where: { $0.eIris }) {
            Button(array.hybridPushableCount > 0
                   ? "Push e-iris → target"
                   : "e-iris in tolerance") {
                array.pushAllHybridApertures()
            }
            .buttonStyle(DarkButtonStyle(prominent: array.hybridPushableCount > 0))
            .disabled(array.hybridPushableCount == 0)
            .help("Push this e-iris body one step toward the target. Re-press after it settles to converge — the same feedback loop as a hand on a manual ring.")
        }
    }

    @ViewBuilder
    private var trimFocus: some View {
        if let active = array.fullScreenNode, array.isManualParticipant(active) {
            ManualTrimFocus(node: active)
        } else if let node = array.calibrationCamera, array.manualSessionActive {
            ManualCameraRow(node: node)
        }
    }

    // MARK: Roll

    @ViewBuilder
    private var rollSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("CALIBRATION ROLL")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Text("\(array.calibrationRoll.count) camera\(array.calibrationRoll.count == 1 ? "" : "s")")
                    .font(Theme.mono(9.5, weight: .bold))
                    .foregroundStyle(array.calibrationRoll.isEmpty ? Theme.ink3 : Theme.good)
            }

            if array.calibrationRoll.isEmpty {
                Text("Empty. Each camera is written here the moment it certifies — not at the end — so a crash mid-run costs one body, not the set.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let spread = array.calibrationRollSpreadStops {
                    HStack {
                        Text("SET SPREAD")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                        Spacer()
                        Text(String(format: "%.3f st", spread))
                            .font(Theme.mono(10.5, weight: .bold))
                            .foregroundStyle(spread <= array.manualToleranceStops ? Theme.good : Theme.warn)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(array.calibrationRoll) { row in
                        HStack(spacing: 6) {
                            Text(row.displayID)
                                .font(Theme.mono(10, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 34, alignment: .leading)
                            Text("T \(row.stopLabel)")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.ink3)
                            Spacer()
                            Text(String(format: "%.2f IRE", row.finalIRE))
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.ink2)
                            Text(String(format: "%+.3f st", row.correctionStops))
                                .font(Theme.mono(10, weight: .semibold))
                                .foregroundStyle(abs(row.correctionStops) <= array.manualToleranceStops
                                                 ? Theme.good : Theme.warn)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2))

                HStack(spacing: 8) {
                    Button("Save Calibration Roll") { array.saveCalibrationRoll() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(array.manualSessionActive)
                    if confirmingClearRoll {
                        Button("Confirm clear") {
                            array.clearCalibrationRoll()
                            confirmingClearRoll = false
                        }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                        Button("Cancel") { confirmingClearRoll = false }
                            .buttonStyle(DarkButtonStyle())
                    } else {
                        Button("Clear roll") { confirmingClearRoll = true }
                            .buttonStyle(DarkButtonStyle())
                            .disabled(array.manualSessionActive)
                    }
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2.opacity(0.6)))
    }

    // MARK: Bits

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var headerCount: String {
        array.calibrationRunActive
            ? "\(min(array.calibrationQueueIndex + 1, array.calibrationRunTotal))/\(array.calibrationRunTotal)"
            : "\(array.calibrationRoll.count) recorded"
    }

    private var focusedDeltaText: String {
        guard let node = array.calibrationCamera,
              let delta = node.manualMatch.deltaIRE else { return "—" }
        return String(format: "%+.2f IRE", delta)
    }

    private var focusedCorrectionText: String {
        guard let node = array.calibrationCamera,
              let correction = node.manualMatch.correctionStops,
              correction.isFinite else { return "—" }
        return String(format: "%+.3f st", correction)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink3)
            Text(value)
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2))
    }

    private var phaseColor: Color {
        switch array.manualPhase {
        case .complete, .finished: return Theme.good
        case .failed: return Theme.danger
        case .preparing, .restoring: return Theme.warn
        case .trimming: return Theme.accent
        case .idle: return Theme.idle
        }
    }
}

struct ManualTrimFocus: View {
    @ObservedObject var node: CameraNode

    var info: ManualMatchInfo { node.manualMatch }
    private var cueColor: Color { ManualCueStyle.color(info.phase) }
    private var trimming: Bool { info.phase == .open || info.phase == .close }
    private var recovering: Bool { info.phase == .recovering || node.streamRecovering }

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(node.status.name.isEmpty ? node.ip : node.status.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("ACTIVE CAMERA")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.accent)
            }
            if recovering {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(Theme.warn)
                    ManualRecoveryText(size: 19)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                HStack(spacing: 10) {
                    HoldRing(phase: info.phase, stability: info.stability, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.phase.rawValue)
                            .font(.system(size: 19, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(cueColor)
                        if info.phase == .hold {
                            Text("hold steady…")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                    if trimming {
                        TrimChevrons(direction: info.phase == .open ? 1 : -1,
                                     magnitudeStops: info.correctionStops ?? 0,
                                     color: cueColor)
                    }
                    Spacer()
                    if let correction = info.correctionStops, trimming {
                        Text(String(format: "%+.2f ST", correction))
                            .font(Theme.mono(18, weight: .bold))
                            .foregroundStyle(cueColor)
                            .help("Signed iris move: + open, − close")
                    }
                }
                ManualTrimGauge(correctionStops: info.correctionStops.map { -$0 },
                                toleranceStops: info.toleranceStops,
                                color: cueColor)
                    .frame(height: 30)
                HStack {
                    Text(info.currentIRE.map { String(format: "%.1f IRE", $0) } ?? "—")
                    Spacer()
                    Text(String(format: "band ±%.2f ST", info.toleranceStops))
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                    Text(info.targetIRE.map { String(format: "target %.0f", $0) } ?? "target —")
                }
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel3))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(cueColor.opacity(0.55), lineWidth: 1))
    }
}

struct ManualCameraRow: View {
    @EnvironmentObject var array: ArrayController
    @ObservedObject var node: CameraNode

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if array.manualPhase == .trimming {
                    array.selectManualCamera(node)
                } else {
                    array.selectedNodeID = node.id
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(stateColor).frame(width: 6, height: 6)
                    Text(node.status.name.isEmpty ? node.ip : node.status.name)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    // e-iris badge so the operator can see at a glance which
                    // bodies Hybrid can drive vs. which need a hand on the ring.
                    if node.eIris {
                        Text("E-IRIS")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accentBG))
                    }
                    Spacer()
                    Text(node.manualMatch.currentIRE.map { String(format: "%.1f", $0) } ?? "—")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink3)
                    Text(correctionText)
                        .font(Theme.mono(10, weight: .bold))
                        .foregroundStyle(stateColor)
                        .frame(width: 58, alignment: .trailing)
                    Text(node.manualMatch.phase.rawValue)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(stateColor)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(array.selectedNodeID == node.id ? Theme.accentBG : Color.clear))
            }
            .buttonStyle(.plain)

            // Operator-approved push: only for e-iris participants, enabled when a
            // real correction is pending. Manual glass shows no push affordance.
            if node.eIris {
                Button("PUSH") { array.pushHybridAperture(node) }
                    .font(.system(size: 8.5, weight: .bold))
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!array.canPushHybrid(node))
                    .help("Send this e-iris body one step toward the shared target. Re-press after it settles to converge.")
            }
        }
    }

    var correctionText: String {
        guard let correction = node.manualMatch.correctionStops else { return "—" }
        return String(format: "%+.2fst", correction)
    }

    var stateColor: Color {
        switch node.manualMatch.phase {
        case .matched: return Theme.good
        case .hold: return Theme.accent
        case .open, .close: return Theme.warn
        case .recovering: return Theme.warn
        case .unavailable: return Theme.danger
        case .acquiring, .idle: return Theme.idle
        }
    }
}

// MARK: - Iris Match panel

struct IrisMatchPanel: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Iris Match", count: "\(array.nodes.filter(\.eIris).count) e-iris")
            Text("Push one T-stop to every e-iris body — the loop's starting state. Same T ≠ matched exposure: lens variance is what the loop then corrects.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("stop", text: $array.linkStopText)
                    .darkField()
                    .frame(width: 58)
                Button("Push to Array") { array.pushLinkedStop() }
                    .buttonStyle(DarkButtonStyle(prominent: true))
                    .disabled(array.linkStopX10 == nil || array.loopRunning)
            }
            HStack(spacing: 6) {
                Button("Set Log3G10 on Array") { array.setLog3G10OnArray() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(array.loopRunning || array.nodes.allSatisfy { !$0.connected })
                    .help("One deliberate rule-11 action per connected body: capture the current preset for restore, then set only the monitor output feeding the livestream mirror to Log3G10 and read it back. Record-side image settings are untouched.")
                Button("Restore Presets\(array.savedPresetCount > 0 ? " (\(array.savedPresetCount))" : "")") {
                    array.restorePresetsOnArray()
                }
                .buttonStyle(DarkButtonStyle())
                .disabled(array.savedPresetCount == 0 || array.loopRunning)
                .help("Array-wide undo of Set Log3G10: put every captured pre-swap preset back on its body. Run this before wrapping the session. Bodies whose mirror output changed mid-session are refused conservatively and keep their saved value.")
            }
        }
        .panelCard()
    }
}

// MARK: - Match loop panel

struct MatchLoopPanel: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Exposure Match", count: statusPill, warn: array.loopRunning)
            Text(array.loopUsesLog3G10
                 ? "Log3G10 confirmed: linearize hero levels → computed ¼-stop move (max 8 steps) → settle → debounce → verify."
                 : "Transform preflight chooses Log3G10 multi-step precision or the bounded sign-only fallback; mixed transforms are blocked.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Reference", selection: $array.referenceMode) {
                ForEach(ArrayController.ReferenceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .font(.system(size: 11))
            .disabled(array.loopRunning)

            if array.referenceMode == .gray18 {
                Text(String(format: "target: %.1f IRE in Log3G10 · ~%.0f IRE via IPP2 (provisional)",
                            Log3G10.grayAnchorIRE, ArrayController.ipp2GrayAnchorIRE))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.ink3)
            } else if array.referenceMode == .custom {
                HStack(spacing: 6) {
                    TextField("IRE", text: $array.loopTargetText)
                        .darkField()
                        .frame(width: 56)
                        .disabled(array.loopRunning)
                    Text("target IRE in the ACTIVE transform")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.ink3)
                }
            }

            configRow("IRE fallback", String(format: "±%.1f", array.toleranceIRE)) {
                Slider(value: $array.toleranceIRE, in: 0.5...6.0, step: 0.5)
            }
            configRow("Log tolerance", String(format: "±%.3fst", array.toleranceStops)) {
                Slider(value: $array.toleranceStops, in: 0.01...0.20, step: 0.01)
            }
            configRow("DoF budget", "\(array.nudgeBudget) steps") {
                Slider(value: Binding(
                    get: { Double(array.nudgeBudget) },
                    set: { array.nudgeBudget = Int($0) }
                ), in: 1...24, step: 1)
            }
            configRow("Debounce", String(format: "%.1f s", array.debounceSeconds)) {
                Slider(value: $array.debounceSeconds, in: 0.5...5.0, step: 0.5)
            }

            HStack(spacing: 8) {
                if array.loopRunning {
                    Button("Abort") { array.stopMatch() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                } else {
                    Button("Start Match") { array.startMatch() }
                        .disabled(array.referenceMode == .custom && array.loopCustomTargetIRE == nil)
                        .buttonStyle(DarkButtonStyle(prominent: true))
                }
                if let ref = array.referenceIRE {
                    Text(String(format: "ref %.1f IRE", ref))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer()
            }

            if case .finished(let text) = array.loopState {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Array-wide manual override — a deliberate global bias after the
            // match has landed. Only live while the loop is idle so it can never
            // fight convergence.
            if array.matchWorkflow == .electronic, !array.loopRunning,
               array.nodes.contains(where: { array.canOverride($0) }) {
                HStack(spacing: 8) {
                    Text("ARRAY OVERRIDE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                    Button("Open all") { array.overrideNudgeAll(open: true) }
                        .buttonStyle(DarkButtonStyle())
                    Button("Close all") { array.overrideNudgeAll(open: false) }
                        .buttonStyle(DarkButtonStyle())
                }
                .help("Nudge every e-iris body one step the same direction. The loop never auto-undoes an override — re-run the match to clear it.")
            }

            // Per-camera delta table
            let active = array.nodes.filter { $0.match.phase != .idle || $0.match.manualOverride }
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(active) { node in
                        HStack(spacing: 8) {
                            Text(node.ip)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.ink3)
                                .frame(width: 100, alignment: .leading)
                            Text(deltaText(node))
                                .font(Theme.mono(10, weight: .semibold))
                                .foregroundStyle(deltaColor(node))
                                .frame(width: 42, alignment: .trailing)
                            Text(phaseText(node))
                                .font(.system(size: 10, weight: node.match.manualOverride ? .bold : .regular))
                                .foregroundStyle(node.match.manualOverride ? Theme.accent : Theme.ink2)
                                .lineLimit(1)
                            Spacer()
                            // Per-camera override: click the lens open/closed one
                            // step. Shown for e-iris bodies while the loop is idle;
                            // otherwise the row shows the auto nudges spent.
                            if array.canOverride(node) {
                                Button("Open") { array.overrideNudge(node, open: true) }
                                    .buttonStyle(DarkButtonStyle())
                                    .help("Open this lens one list step (more exposure). Manual override — the loop won't undo it; re-run the match to clear.")
                                Button("Close") { array.overrideNudge(node, open: false) }
                                    .buttonStyle(DarkButtonStyle())
                                    .help("Close this lens one list step (less exposure). Manual override — the loop won't undo it; re-run the match to clear.")
                            } else {
                                Text("\(node.match.nudgesUsed)")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2))
            }
        }
        .panelCard()
    }

    /// Match-loop phase text with the manual-override tag appended so an
    /// overridden camera reads e.g. "matched · override (1 close)".
    func phaseText(_ node: CameraNode) -> String {
        guard node.match.manualOverride else { return node.match.phase.rawValue }
        let n = node.match.overrideSteps
        let tail = n == 0 ? "" : (n < 0 ? " (\(abs(n)) open)" : " (\(abs(n)) close)")
        let base = node.match.phase == .idle ? "set" : node.match.phase.rawValue
        return "\(base) · override\(tail)"
    }

    var statusPill: String {
        switch array.loopState {
        case .idle: return "idle"
        case .running(let round): return "round \(round)"
        case .finished: return "done"
        }
    }

    func deltaColor(_ node: CameraNode) -> Color {
        if array.loopUsesLog3G10, let d = node.match.deltaStops {
            return abs(d) <= array.toleranceStops ? Theme.good : Theme.warn
        }
        guard let d = node.match.deltaIRE else { return Theme.ink3 }
        return abs(d) <= array.toleranceIRE ? Theme.good : Theme.warn
    }

    func deltaText(_ node: CameraNode) -> String {
        if array.loopUsesLog3G10 {
            return node.match.deltaStops.map { String(format: "%+.3f", $0) } ?? "—"
        }
        return node.match.deltaIRE.map { String(format: "%+.1f", $0) } ?? "—"
    }

    @ViewBuilder
    func configRow<S: View>(_ label: String, _ value: String, @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink2)
                .frame(width: 78, alignment: .leading)
            slider()
                .controlSize(.small)
                .disabled(array.loopRunning)
            Text(value)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

// MARK: - Live Sphere Soak panel

struct SoakPanel: View {
    @EnvironmentObject var array: ArrayController
    @ObservedObject var soak: SoakRecorder

    init(soak: SoakRecorder) {
        self.soak = soak
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Soak", count: statusText, warn: soak.isRecording)
            Text("Runs the exact live analysis path used by Exposure Match. Every tick streams to CSV; only 300 recent rows per camera stay in memory.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Duration", selection: $array.soakDuration) {
                ForEach(SoakDurationOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .font(.system(size: 11))
            .disabled(soak.isRecording)

            HStack(spacing: 8) {
                if soak.isRecording {
                    Button("Stop Soak") { array.stopSoak() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                } else {
                    Button("Start Soak…") { array.startSoak() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(array.nodes.isEmpty)
                }
                if !soak.lastError.isEmpty {
                    Text(soak.lastError)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                }
                Spacer()
            }

            let live = soak.snapshot
            HStack(spacing: 6) {
                statChip("TICKS", "\(live.totalTicks)")
                statChip("LOCKS", "\(live.lockedTicks)")
                statChip("JITTER", String(format: "%.2fpx", live.worstCenterJitterPixel))
                statChip("IRE σ", String(format: "%.2f", live.worstIREStd))
            }
            if let ire = live.pairwiseIRESpread, let stops = live.pairwiseDisplayStops {
                Text(String(format: "readiness spread  %.2f IRE  /  %.3f display stops", ire, stops))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.ink2)
            }

            if !live.cameras.isEmpty {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        tableHeader("CAMERA", width: 100, alignment: .leading)
                        tableHeader("DET%", width: 42)
                        tableHeader("JIT PX", width: 48)
                        tableHeader("IRE σ", width: 44)
                        Spacer()
                    }
                    ForEach(live.cameras) { metric in
                        HStack(spacing: 8) {
                            Text(metric.cameraIP)
                                .frame(width: 100, alignment: .leading)
                            Text(String(format: "%.1f", metric.detectionPercent))
                                .frame(width: 42, alignment: .trailing)
                                .foregroundStyle(metric.detectionPercent >= 99 ? Theme.good : Theme.warn)
                            Text(String(format: "%.2f", metric.centerJitterPixel))
                                .frame(width: 48, alignment: .trailing)
                            Text(String(format: "%.2f", metric.ireStd))
                                .frame(width: 44, alignment: .trailing)
                            Spacer()
                        }
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink2)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2))
            }
        }
        .panelCard()
    }

    var statusText: String {
        soak.isRecording ? Self.duration(soak.snapshot.elapsed) : "idle"
    }

    func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8, weight: .bold)).tracking(0.7)
                .foregroundStyle(Theme.ink3)
            Text(value).font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2))
    }

    func tableHeader(_ text: String, width: CGFloat,
                     alignment: Alignment = .trailing) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.ink3)
            .frame(width: width, alignment: alignment)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Waveform panel

struct WaveformPanel: View {
    @ObservedObject var node: CameraNode

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Waveform", count: node.status.name.isEmpty ? node.ip : node.status.name)
            WaveformView(grid: node.waveform, sphereIRE: node.sphere.heroIRE)
                .frame(height: 140)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.line, lineWidth: 1))
        }
        .panelCard()
    }
}

struct WaveformView: View {
    let grid: WaveformGrid?
    let sphereIRE: Double?

    var body: some View {
        Canvas { ctx, size in
            guard let grid else { return }
            let cols = WaveformGrid.columns
            let levels = WaveformGrid.levels
            let cw = size.width / CGFloat(cols)
            let lh = size.height / CGFloat(levels)
            for c in 0..<cols {
                for l in 0..<levels {
                    let v = grid.intensity[c * levels + l]
                    guard v > 0.02 else { continue }
                    let rect = CGRect(
                        x: CGFloat(c) * cw,
                        y: size.height - CGFloat(l + 1) * lh,   // level 0 at bottom
                        width: cw.rounded(.up), height: lh.rounded(.up))
                    ctx.fill(Path(rect), with: .color(Theme.good.opacity(Double(min(1, v * 0.9 + 0.1)))))
                }
            }
            // Sphere hero-IRE marker line
            if let ire = sphereIRE {
                let y = size.height * (1 - CGFloat(min(max(ire / 100.0, 0), 1)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(Theme.warn), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }
}

// MARK: - Array log

struct ArrayLogPane: View {
    @EnvironmentObject var array: ArrayController

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ARRAY LOG")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(array.logText(), forType: .string)
                }
                .buttonStyle(DarkButtonStyle())
                Button("Save Log…") { array.saveLog() }
                    .buttonStyle(DarkButtonStyle())
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.panel2.opacity(0.7))
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(array.logLines) { line in
                            Text("\(Self.timeFmt.string(from: line.date))  \(line.text)")
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.ink2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: array.logLines.count) {
                    if let last = array.logLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Theme.bg1.opacity(0.5))
    }
}

// Panel card + field styles come from UI/Theme.swift (shared with the Bench tab).
