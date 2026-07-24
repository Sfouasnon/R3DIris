//  ContentView.swift — R3DIris root chrome + Phase 0 bench tool.
//  Custom chrome (no system TabView): iris wordmark top-left, Bench/Array
//  switcher, shared graphite identity from UI/Theme.swift.
//  Bench tab = Phase 0 single-body checklists (RCP2_APERTURE_NOTES.md §Bench,
//  RCP2_LIVESTREAM_NOTES.md §Bench). Array tab = Phase 2 (IRIS_MATCH_NOTES.md).

import SwiftUI

struct ContentView: View {
    enum Tab: String, CaseIterable {
        case bench = "Bench"
        case array = "Array"
    }
    @State private var tab: Tab = .bench

    var body: some View {
        ZStack {
            Theme.appBackground
            VStack(spacing: 0) {
                TopBar(tab: $tab)
                Rectangle().fill(Theme.line).frame(height: 1)
                switch tab {
                case .bench: BenchRootView()
                case .array: ArrayView()
                }
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 640)
    }
}

// MARK: - Top bar (logo · tab switcher · status)

struct TopBar: View {
    @Binding var tab: ContentView.Tab

    var body: some View {
        HStack(spacing: 14) {
            IrisWordmark()
                .padding(.leading, 76)   // clear the traffic lights (hidden title bar)

            // Tab switcher
            HStack(spacing: 2) {
                ForEach(ContentView.Tab.allCases, id: \.self) { t in
                    Button {
                        tab = t
                    } label: {
                        Text(t.rawValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Capsule().fill(tab == t ? Theme.panel3 : .clear))
                            .overlay(Capsule().stroke(tab == t ? Theme.line2 : .clear, lineWidth: 1))
                            .foregroundStyle(tab == t ? Theme.ink : Theme.ink3)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.panel2))
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))

            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.bg1.opacity(0.8))
    }
}

// MARK: - Bench tab (Phase 0)

struct BenchRootView: View {
    @EnvironmentObject var bench: BenchController

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Rectangle().fill(Theme.line).frame(height: 1)
            HSplitView {
                VStack(spacing: 0) {
                    // stream is a nested ObservableObject — pass it explicitly so
                    // its @Published changes actually invalidate these views.
                    LiveView(stream: bench.stream, validation: bench.validation)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    LogPane()
                        .frame(minHeight: 140, idealHeight: 200)
                }
                .frame(minWidth: 480)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LivestreamPanel(stream: bench.stream)
                        IREValidationPanel(validation: bench.validation)
                        AperturePanel()
                        Spacer()
                    }
                    .padding(14)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                .background(Theme.bg1.opacity(0.6))
            }
        }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var bench: BenchController

    var body: some View {
        HStack(spacing: 10) {
            TextField("camera IP", text: $bench.ip)
                .darkField()
                .frame(width: 130)
                .disabled(bench.status.link == .connected || bench.status.link == .connecting)
            TextField("source IP (rule 16, optional)", text: $bench.sourceIP)
                .darkField()
                .frame(width: 170)
                .disabled(bench.status.link == .connected || bench.status.link == .connecting)

            switch bench.status.link {
            case .disconnected, .parked:
                Button("Connect") { bench.connect() }
                    .buttonStyle(DarkButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(bench.validation.isBusy)
                if bench.status.link == .parked {
                    Button("Refresh") { bench.refresh() }
                        .buttonStyle(DarkButtonStyle())
                        .disabled(bench.validation.isBusy)
                }
            case .connecting:
                Button("Cancel") { bench.disconnect() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(bench.validation.isBusy)
                ProgressView().controlSize(.small)
            case .connected:
                Button("Disconnect") { bench.disconnect() }
                    .buttonStyle(DarkButtonStyle(destructive: true))
                    .disabled(bench.validation.isBusy)
                Button("Refresh") { bench.refresh() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(bench.validation.isBusy)
            }

            LinkBadge(state: bench.status.link)

            if bench.status.link == .connected {
                Text(bench.status.name.isEmpty ? "—" : bench.status.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("FW \(bench.status.firmware)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.ink3)
                Text(bench.status.currentTC.isEmpty ? "--:--:--" : bench.status.currentTC)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(bench.status.tcLock ? Theme.ink2 : Theme.warn)
                    .help("TC push at 1/s = link alive. Amber = no recent TC (possible wedge).")
                Text(bench.status.recordStateLabel)
                    .font(Theme.mono(9.5, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(bench.status.recordState == 1 ? Theme.dangerBG : Theme.idleBG))
                    .foregroundStyle(bench.status.recordState == 1 ? Theme.danger : Theme.ink2)
            } else if !bench.status.lastError.isEmpty {
                Text(bench.status.lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel2.opacity(0.7))
    }
}

struct LinkBadge: View {
    let state: LinkState

    var level: StatusDot.Level {
        switch state {
        case .connected: return .ok
        case .connecting: return .warn
        case .parked: return .fail
        case .disconnected: return .off
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(level: level)
            Text(state.rawValue.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink3)
        }
    }
}

// MARK: - Live view

struct LiveView: View {
    @ObservedObject var stream: MJPEGStreamReader
    @ObservedObject var validation: IREValidationController

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let rect = fittedImageRect(in: proxy.size)
                ZStack {
                    Rectangle().fill(Color.black)
                    if let frame = stream.frame {
                        Image(decorative: frame, scale: 1.0)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        IREValidationOverlay(validation: validation, imageRect: rect)
                    } else {
                        Text(stream.isStreaming ? "waiting for first frame…" : "no stream")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { gesture in
                            guard stream.frame != nil, rect.contains(gesture.location),
                                  rect.width > 0, rect.height > 0 else { return }
                            validation.addSelectionPoint(
                                IRENormalizedPoint(
                                    x: (gesture.location.x - rect.minX) / rect.width,
                                    y: (gesture.location.y - rect.minY) / rect.height
                                )
                            )
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            let s = stream.stats
            HStack(spacing: 16) {
                stat("frames", "\(s.frames)")
                stat("size", s.width > 0 ? "\(s.width)×\(s.height)" : "—")
                stat("fps", s.fps > 0 ? String(format: "%.1f", s.fps) : "—")
                stat("rate", s.bytesPerSecond > 0 ? String(format: "%.2f Mb/s", s.bytesPerSecond * 8 / 1_000_000) : "—")
                if !stream.lastError.isEmpty {
                    Text(stream.lastError)
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 10.5))
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink3)
            Text(value)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink2)
        }
    }

    private func fittedImageRect(in container: CGSize) -> CGRect {
        guard let frame = stream.frame, frame.width > 0, frame.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let imageAspect = CGFloat(frame.width) / CGFloat(frame.height)
        let containerAspect = container.width / container.height
        let size: CGSize
        if imageAspect > containerAspect {
            size = CGSize(width: container.width, height: container.width / imageAspect)
        } else {
            size = CGSize(width: container.height * imageAspect, height: container.height)
        }
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Livestream bench panel

struct LivestreamPanel: View {
    @EnvironmentObject var bench: BenchController
    @ObservedObject var stream: MJPEGStreamReader
    @State private var quality = 4   // measure at Q100 (LIVESTREAM_NOTES)

    var connected: Bool { bench.status.link == .connected }
    private var qualityOptions: [LivestreamQualityOption] {
        bench.status.livestreamQualityOptions.isEmpty
            ? (1...4).map {
                .init(value: $0, label: RCP2.livestreamQualityLabels[$0] ?? "\($0)")
            }
            : bench.status.livestreamQualityOptions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Livestream — Bench", count: stream.isStreaming ? "live" : "")
            Text("Multipart-HTTP JPEG on :9090 — separate from the RCP2 WS.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button(stream.isStreaming ? "Streaming…" : "Enable + View") {
                    bench.enableLivestreamAndView()
                }
                .buttonStyle(DarkButtonStyle(prominent: true))
                .disabled(!connected || stream.isStreaming || bench.validation.isBusy)
                Button("Stop") { bench.stopLivestream() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!stream.isStreaming || bench.validation.isBusy)
            }

            HStack(spacing: 6) {
                Picker("Quality", selection: $quality) {
                    ForEach(qualityOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .font(.system(size: 11))
                .frame(width: 140)
                .disabled(bench.validation.isBusy)
                Button("Set") { bench.setQuality(quality) }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!connected || bench.validation.isBusy)
            }

            Text("RCP2 wire factors are Q25/Q50/Q75/Q100. Capture records the camera-advertised list and actual read-back.")
                .font(.system(size: 9.8))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            Button("Read mirror source + rect") { bench.readMirrorAndRect() }
                .buttonStyle(DarkButtonStyle())
                .disabled(!connected || bench.validation.isBusy)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("enabled").foregroundStyle(Theme.ink3)
                    Text(bench.status.livestreamEnabled.map(String.init) ?? "—")
                        .foregroundStyle(Theme.ink)
                }
                GridRow {
                    Text("quality").foregroundStyle(Theme.ink3)
                    Text(bench.status.livestreamQuality.flatMap { RCP2.livestreamQualityLabels[$0] } ?? "—")
                        .foregroundStyle(Theme.ink)
                }
                GridRow {
                    Text("mirror").foregroundStyle(Theme.ink3)
                    Text(bench.status.mirrorSource.flatMap { RCP2.mirrorSourceLabels[$0] } ?? "—")
                        .foregroundStyle(Theme.ink)
                }
            }
            .font(Theme.mono(10.5))
        }
        .panelCard()
        .onChange(of: bench.status.livestreamQualityOptions) {
            guard !qualityOptions.contains(where: { $0.value == quality }) else { return }
            quality = bench.status.livestreamQuality
                .flatMap { actual in qualityOptions.first(where: { $0.value == actual })?.value }
                ?? qualityOptions.last?.value
                ?? quality
        }
    }
}

// MARK: - Aperture bench panel

struct AperturePanel: View {
    @EnvironmentObject var bench: BenchController
    @State private var stopText = "5.6"

    var connected: Bool { bench.status.link == .connected }

    /// "5.6" -> 56, "11" -> 110 (encoding: stop ×10)
    var stopX10: Int? {
        guard let v = Double(stopText.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return Int((v * 10).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader(title: "Aperture — Bench", count: "", warn: true)
            Text("All params # UNVERIFIED (rule 11): each button is one deliberate get/set on a session you're prepared to lose. Watch TC keep ticking after each.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            // Checklist steps 1–3: gates + first reads
            VStack(alignment: .leading, spacing: 5) {
                Button("1. Check APERTURE_CONTROL (e-iris gate)") { bench.checkApertureControl() }
                    .buttonStyle(DarkButtonStyle())
                Button("2. Get APERTURE (rule-11 first touch)") { bench.getAperture() }
                    .buttonStyle(DarkButtonStyle())
                Button("3. Get valid stop list (lens range)") { bench.getApertureList() }
                    .buttonStyle(DarkButtonStyle())
                Button("Get APERTURE_LIST_MODE (¼ vs ⅓ stop)") { bench.getApertureListMode() }
                    .buttonStyle(DarkButtonStyle())
                Button("Check AE (must be OFF or aperture-locked)") { bench.checkAE() }
                    .buttonStyle(DarkButtonStyle())
                Toggle("Subscribe APERTURE (pushed cur/target = settle detector)",
                       isOn: Binding(get: { bench.apertureSubscribed },
                                     set: { _ in bench.toggleApertureSubscription() }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
            }
            .disabled(!connected || bench.validation.isBusy)

            Rectangle().fill(Theme.line).frame(height: 1)

            // Steps 4–5: moves
            HStack(spacing: 6) {
                TextField("stop", text: $stopText)
                    .darkField()
                    .frame(width: 56)
                    .disabled(bench.validation.isBusy)
                Button("4. Set") {
                    if let x10 = stopX10 { bench.setAperture(stopX10: x10) }
                }
                .buttonStyle(DarkButtonStyle(prominent: true))
                .disabled(!connected || stopX10 == nil || bench.validation.isBusy)
                Spacer()
                Button("5. Nudge −") { bench.nudgeAperture(-1) }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!connected || bench.validation.isBusy)
                Button("Nudge +") { bench.nudgeAperture(1) }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!connected || bench.validation.isBusy)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("cur").foregroundStyle(Theme.ink3)
                    Text(RCP2.stopLabel(bench.status.apertureCur))
                        .foregroundStyle(Theme.ink)
                }
                GridRow {
                    Text("target").foregroundStyle(Theme.ink3)
                    Text(RCP2.stopLabel(bench.status.apertureTarget))
                        .foregroundStyle(Theme.ink)
                }
                GridRow {
                    Text("settled").foregroundStyle(Theme.ink3)
                    Text(bench.status.apertureSettled ? "YES" : "no")
                        .foregroundStyle(bench.status.apertureSettled ? Theme.good : Theme.warn)
                }
                GridRow {
                    Text("e-iris").foregroundStyle(Theme.ink3)
                    Text(bench.status.apertureControl.map { $0 == 1 ? "SUPPORTED" : "NOT SUPPORTED" } ?? "—")
                        .foregroundStyle(Theme.ink)
                }
                GridRow {
                    Text("steps").foregroundStyle(Theme.ink3)
                    Text(bench.status.apertureListMode.map { $0 == 0 ? "1/4 stop" : "1/3 stop" } ?? "—")
                        .foregroundStyle(Theme.ink)
                }
            }
            .font(Theme.mono(10.5))
        }
        .panelCard()
    }
}

// MARK: - Log pane

struct LogPane: View {
    @EnvironmentObject var bench: BenchController

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BENCH LOG")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bench.logText(), forType: .string)
                }
                .buttonStyle(DarkButtonStyle())
                Button("Save Log…") { bench.saveLog() }
                    .buttonStyle(DarkButtonStyle())
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.panel2.opacity(0.7))
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(bench.logLines) { line in
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
                .onChange(of: bench.logLines.count) {
                    if let last = bench.logLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Theme.bg1.opacity(0.5))
    }
}
