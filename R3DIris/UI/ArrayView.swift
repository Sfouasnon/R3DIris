//  ArrayView.swift — R3DIris / Array (Phase 2)
//  The Iris Match surface, in R3DIris's own identity (UI/Theme.swift):
//  discovery toolbar (TCP sweep primary, CAMINFO fallback, manual IP as the
//  fallback path) · camera-tile grid (live view + sphere overlay + aperture
//  state) · Iris Match / Exposure Match panels · waveform · array log.
//  Root chrome (background, logo, tab switcher) lives in ContentView.

import SwiftUI

struct ArrayView: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
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
                        if array.matchWorkflow == .electronic {
                            IrisMatchPanel()
                            MatchLoopPanel()
                        } else {
                            ManualAssistPanel()
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
            TextField("subnet / CIDR (172.20.114.0/24)", text: $array.subnet)
                .darkField()
                .frame(width: 200)
                .onSubmit { array.discover() }
                .disabled(array.discovering)
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
            : "No subnet set — CAMINFO broadcast only. Enter a subnet/CIDR to enable the TCP sweep."
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
                if array.matchWorkflow == .manual, array.manualSessionActive,
                   node.manualMatch.phase != .idle {
                    ManualCameraHUD(info: node.manualMatch, selected: selected)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
            }

            // Identity row
            HStack(spacing: 7) {
                StatusDot(level: linkLevel)
                Text(node.status.name.isEmpty ? node.ip : node.status.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !node.status.name.isEmpty {
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
                Spacer()
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
                    Button("Re-detect") { node.redetect() }
                        .buttonStyle(DarkButtonStyle())
                        .disabled(!stream.isStreaming)
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
        .onTapGesture { array.selectedNodeID = node.id }
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
        return "Livestream viewing transform: \(pid) = \(value). # UNVERIFIED until the transform bench checklist passes."
    }

    @ViewBuilder
    var matchChip: some View {
        if array.matchWorkflow == .manual, array.manualSessionActive,
           node.manualMatch.phase != .idle {
            Text(manualMatchLabel)
                .font(Theme.mono(10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(manualMatchBG))
                .foregroundStyle(manualMatchInk)
                .help(node.manualMatch.detail)
        } else if node.match.phase != .idle {
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
        case .unavailable: return Theme.dangerBG
        case .acquiring, .idle: return Theme.idleBG
        }
    }

    var manualMatchInk: Color {
        switch node.manualMatch.phase {
        case .matched: return Theme.good
        case .hold: return Theme.accent
        case .open, .close: return Theme.warn
        case .unavailable: return Theme.danger
        case .acquiring, .idle: return Theme.idle
        }
    }

    var matchLabel: String {
        if array.loopUsesLog3G10, let d = node.match.deltaStops {
            return String(format: "%@ %+.3fst", node.match.phase.rawValue, d)
        }
        if let d = node.match.deltaIRE {
            return String(format: "%@ %+.1f", node.match.phase.rawValue, d)
        }
        return node.match.phase.rawValue
    }

    var matchBG: Color {
        switch node.match.phase {
        case .matched: return Theme.goodBG
        case .adjusting: return Theme.accentBG
        case .capped, .oscillating: return Theme.warnBG
        case .excluded: return Theme.idleBG
        case .idle: return .clear
        }
    }

    var matchInk: Color {
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
struct ManualCameraHUD: View {
    let info: ManualMatchInfo
    let selected: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.62), .clear, Color.black.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 5) {
                HStack {
                    Text("MANUAL TRIM")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(selected ? Theme.accent : Theme.ink2)
                    Spacer()
                    if let current = info.currentIRE, let target = info.targetIRE {
                        Text(String(format: "%.1f → %.1f IRE", current, target))
                            .font(Theme.mono(9.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 7) {
                    Image(systemName: cueIcon)
                        .font(.system(size: 15, weight: .bold))
                    Text(info.phase.rawValue)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .tracking(1.4)
                    if let correction = info.correctionStops,
                       info.phase == .open || info.phase == .close {
                        Text(String(format: "%.2f ST", abs(correction)))
                            .font(Theme.mono(13, weight: .bold))
                    }
                }
                .foregroundStyle(cueColor)
                .shadow(color: cueColor.opacity(0.45), radius: 5)

                ManualTrimGauge(correctionStops: info.correctionStops,
                                stability: info.stability,
                                color: cueColor)
                    .frame(height: 24)
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

    var cueIcon: String {
        switch info.phase {
        case .open: return "arrow.right"
        case .close: return "arrow.left"
        case .hold: return "scope"
        case .matched: return "checkmark.seal.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .acquiring: return "viewfinder"
        case .idle: return "circle"
        }
    }

    var cueColor: Color {
        switch info.phase {
        case .matched: return Theme.good
        case .hold: return Theme.accent
        case .open, .close: return Theme.warn
        case .unavailable: return Theme.danger
        case .acquiring, .idle: return Theme.idle
        }
    }
}

struct ManualTrimGauge: View {
    let correctionStops: Double?
    let stability: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let center = width / 2
            let normalized = min(1, max(-1, correctionStops ?? 0))
            let markerX = center + CGFloat(normalized) * max(0, center - 8)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.55)).frame(height: 8)
                Capsule().stroke(Theme.line2, lineWidth: 1).frame(height: 8)
                Rectangle()
                    .fill(Theme.good.opacity(0.28))
                    .frame(width: max(8, width * 0.08), height: 12)
                    .position(x: center, y: geo.size.height / 2)
                Rectangle()
                    .fill(Theme.good)
                    .frame(width: 1.5, height: 18)
                    .position(x: center, y: geo.size.height / 2)
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: color.opacity(0.7), radius: 4)
                    .position(x: markerX, y: geo.size.height / 2)
                if stability > 0 {
                    Capsule()
                        .trim(from: 0, to: min(1, stability))
                        .stroke(Theme.accent, lineWidth: 2)
                        .frame(height: 16)
                }
                HStack {
                    Text("CLOSE")
                    Spacer()
                    Text("OPEN")
                }
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink3)
                .offset(y: 13)
            }
            .frame(height: 8)
            .position(x: center, y: 7)
        }
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
                let d = sphere.r * 2 * geo.size.width
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: d, height: d)
                    .position(x: sphere.cx * geo.size.width,
                              y: sphere.cy * geo.size.height)
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
            if array.matchWorkflow == .electronic {
                Button("Prepare — e-iris gate + AE check + subscribe") { array.prepareAll() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(array.manualSessionActive)
                    .help("Per body: APERTURE_CONTROL gate, AE warning, valid stop list, APERTURE subscription for the settle detector. One deliberate operator action — rule 11.")
            } else {
                Text("Manual Assist uses live sphere measurements only; it does not query, subscribe, or drive APERTURE.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

            Text(array.matchWorkflow == .electronic
                 ? "Electronic drives supported irises over RCP2 and verifies settle after each move."
                 : "Manual Assist captures a fixed IRE target and gives live OPEN / CLOSE guidance. It never sends an aperture command.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelCard()
    }
}

// MARK: - Manual Assist panel

struct ManualAssistPanel: View {
    @EnvironmentObject var array: ArrayController

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            GroupHeader(title: "Manual Assist",
                        count: manualCount,
                        warn: array.manualSessionActive,
                        danger: array.manualPhase == .failed)

            Text("Captures a fixed target from stable sphere measurements, temporarily normalizes mirrored outputs to Log3G10, and restores their saved presets on Finish or Abort.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
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
            manualConfigRow("Stable hold", String(format: "%.1fs", array.manualHoldSeconds)) {
                Slider(value: $array.manualHoldSeconds, in: 0.5...5.0, step: 0.5)
            }

            HStack(spacing: 8) {
                switch array.manualPhase {
                case .preparing, .trimming:
                    Button("Abort & Restore") { array.abortManualMatch() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                case .complete:
                    Button("Finish & Restore") { array.finishManualMatch() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                    Button("Abort") { array.abortManualMatch() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                case .restoring:
                    ProgressView().controlSize(.small)
                    Text("Restoring…")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                case .idle, .finished, .failed:
                    Button("Capture Target & Start") { array.startManualMatch() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(array.manualTargetMode == .custom && array.manualCustomTargetIRE == nil)
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
                    manualStat("TARGET", array.manualTargetIRE.map { String(format: "%.1f IRE", $0) } ?? "—")
                    manualStat("MATCHED", "\(array.manualMatchedCount)/\(array.manualParticipantCount)")
                    manualStat("SPREAD", array.manualArraySpreadStops.map { String(format: "%.2fst", $0) } ?? "—")
                }
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

            if let selected = array.selectedNode,
               array.isManualParticipant(selected) {
                ManualTrimFocus(node: selected)
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

struct ManualTrimFocus: View {
    @ObservedObject var node: CameraNode

    var info: ManualMatchInfo { node.manualMatch }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(node.status.name.isEmpty ? node.ip : node.status.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("ACTIVE CAMERA")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: cueIcon)
                    .font(.system(size: 17, weight: .bold))
                Text(info.phase.rawValue)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                Spacer()
                if let correction = info.correctionStops {
                    Text(String(format: "%.2f ST", abs(correction)))
                        .font(Theme.mono(18, weight: .bold))
                }
            }
            .foregroundStyle(cueColor)
            ManualTrimGauge(correctionStops: info.correctionStops,
                            stability: info.stability,
                            color: cueColor)
                .frame(height: 26)
            HStack {
                Text(info.currentIRE.map { String(format: "%.1f IRE", $0) } ?? "—")
                Spacer()
                Text(info.targetIRE.map { String(format: "target %.1f", $0) } ?? "target —")
            }
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.ink2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel3))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(cueColor.opacity(0.55), lineWidth: 1))
    }

    var cueIcon: String {
        switch info.phase {
        case .open: return "arrow.right"
        case .close: return "arrow.left"
        case .hold: return "scope"
        case .matched: return "checkmark.seal.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .acquiring: return "viewfinder"
        case .idle: return "circle"
        }
    }

    var cueColor: Color {
        switch info.phase {
        case .matched: return Theme.good
        case .hold: return Theme.accent
        case .open, .close: return Theme.warn
        case .unavailable: return Theme.danger
        case .acquiring, .idle: return Theme.idle
        }
    }
}

struct ManualCameraRow: View {
    @EnvironmentObject var array: ArrayController
    @ObservedObject var node: CameraNode

    var body: some View {
        Button {
            array.selectedNodeID = node.id
        } label: {
            HStack(spacing: 7) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(node.status.name.isEmpty ? node.ip : node.status.name)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
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
            Button("Set Log3G10 on Array") { array.setLog3G10OnArray() }
                .buttonStyle(DarkButtonStyle())
                .disabled(array.loopRunning || array.nodes.allSatisfy { !$0.connected })
                .help("One deliberate rule-11 action per connected body: set only the monitor output feeding the livestream mirror to Log3G10, then read it back. Record-side image settings are untouched. # UNVERIFIED until benched.")
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

            // Per-camera delta table
            let active = array.nodes.filter { $0.match.phase != .idle }
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
                            Text(node.match.phase.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ink2)
                            Spacer()
                            Text("\(node.match.nudgesUsed)")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2))
            }
        }
        .panelCard()
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
