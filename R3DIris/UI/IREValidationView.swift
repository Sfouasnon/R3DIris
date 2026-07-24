//  IREValidationView.swift — R3DIris
//  Bench controls and live native-frame ROI overlay for paired MJPEG / Nobe
//  OmniScope IRE validation.

import SwiftUI

struct IREValidationPanel: View {
    @EnvironmentObject var bench: BenchController
    @ObservedObject var validation: IREValidationController

    private var connected: Bool { bench.status.link == .connected }
    private var actualQualityLabel: String {
        bench.status.livestreamQuality
            .flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupHeader(
                title: "IRE Validation — Nobe / SDI",
                count: validation.isCapturing
                    ? "\(validation.capturedFrames)/\(IREValidationController.requiredFrameCount)"
                    : "\(validation.completedTrials) trials"
            )

            Text("Decisive test: pair each untouched :9090 JPEG set with the simultaneous 10-bit SDI waveform value.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            sessionControls
            Rectangle().fill(Theme.line).frame(height: 1)
            sourceControls
            selectionControls
            referenceControls
            captureControls

            Text(validation.statusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(validation.isCapturing ? Theme.warn : Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if !validation.lastResultText.isEmpty {
                Text(validation.lastResultText)
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
            }

            DisclosureGroup("Operator setup + capture order") {
                VStack(alignment: .leading, spacing: 6) {
                    guidance("1", "Gray card first", "Use a flat, evenly lit interior ROI. This is the cleanest transport/range comparison.")
                    guidance("2", "Macbeth chart second", "Click TL → TR → BR → BL. R3DIris solves the 6×4 perspective grid and records all 24 patches; use a selected neutral patch for the Nobe reference.")
                    guidance("3", "Gray sphere last", "Use the production center probe to quantify sphere/card bias from lighting and BRDF.")
                    Text("Nobe / UltraStudio 3G: select the 10-bit DeckLink/UltraStudio input; use luma or RGBY waveform/pin; set the correct Video vs Full range; use the same patch ROI; disable LUT/ICC transforms, smoothing, and averaging; use 100% sampling/high precision. Enter the stabilized simultaneous SDI value before Capture.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Repeat at every factor returned by the camera's RCP2 quality list: black, 18%, 50 IRE, near-white, then −1, −0.5, +0.5, +1 stop brackets.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.ink2)
        }
        .panelCard()
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(validation.sessionURL == nil ? "Create Evidence Session…" : "New Session…") {
                    validation.chooseNewSession(benchLog: bench.logText())
                }
                .buttonStyle(DarkButtonStyle())
                .disabled(validation.isBusy)
                Button("Reveal") { validation.revealSession() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!validation.canRevealSession)
                Button("Finalize") { validation.finishSession() }
                    .buttonStyle(DarkButtonStyle(prominent: true))
                    .disabled(!validation.hasSession || validation.isBusy)
            }
            if let url = validation.sessionURL {
                Text(url.path)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Subject", selection: $validation.subject) {
                    ForEach(IREValidationSubject.allCases) { subject in
                        Text(subject.label).tag(subject)
                    }
                }
                .frame(maxWidth: .infinity)
                Picker("Stage", selection: $validation.stage) {
                    ForEach(IREValidationStage.allCases.filter {
                        validation.subject == .colorChecker
                            ? $0 == .colorChecker
                            : $0 != .colorChecker
                    }) { stage in
                        Text(stage.label).tag(stage)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .font(.system(size: 10.5))
            .disabled(validation.isBusy)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("actual quality").foregroundStyle(Theme.ink3)
                    Text(actualQualityLabel)
                        .foregroundStyle(bench.status.livestreamQuality == nil ? Theme.warn : Theme.ink)
                }
                GridRow {
                    Text("advertised").foregroundStyle(Theme.ink3)
                    Text(
                        bench.status.livestreamQualityOptions.isEmpty
                            ? "—"
                            : bench.status.livestreamQualityOptions
                                .map { "\($0.label)=\($0.value)" }
                                .joined(separator: " ")
                    )
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                }
                GridRow {
                    Text("transform").foregroundStyle(Theme.ink3)
                    Text(bench.status.monitorTransform.rawValue)
                        .foregroundStyle(
                            bench.status.monitorTransform == .log3G10 ? Theme.good : Theme.warn
                        )
                }
            }
            .font(Theme.mono(9.8))
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(validation.selectionInstruction)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Clear ROI") { validation.resetSelection() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(validation.isBusy || validation.selection.points.isEmpty)
            }
            if validation.subject == .graySphere {
                HStack {
                    Text("sphere radius")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink3)
                    Slider(
                        value: Binding(
                            get: { validation.selection.sphereOuterRadius },
                            set: { validation.selection.sphereOuterRadius = $0 }
                        ),
                        in: 0.015...0.22
                    )
                    Text(String(format: "%.1f%% w", validation.selection.sphereOuterRadius * 100))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 54, alignment: .trailing)
                }
                .disabled(validation.isBusy)
            }
            if validation.subject == .colorChecker {
                Picker(
                    "Nobe neutral",
                    selection: Binding(
                        get: { validation.selection.colorCheckerReferencePatch },
                        set: { validation.selection.colorCheckerReferencePatch = $0 }
                    )
                ) {
                    ForEach(IREColorChecker.neutralPatchIndices, id: \.self) { index in
                        Text(IREColorChecker.name(for: index)).tag(index)
                    }
                }
                .font(.system(size: 10.5))
                .disabled(validation.isBusy)
            }
        }
    }

    private var referenceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Nobe IRE", text: $validation.nobeReferenceText)
                    .darkField()
                    .frame(width: 82)
                    .disabled(validation.isBusy)
                Picker("Range", selection: $validation.nobeSignalRange) {
                    ForEach(IREValidationSignalRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .frame(width: 130)
                .disabled(validation.isBusy)
                Text("simultaneous 10-bit SDI IRE")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
            }
            TextField("operator note / exposure method", text: $validation.operatorNote)
                .darkField()
                .disabled(validation.isBusy)
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button("1. Refresh Read-backs") { bench.prepareIREValidation() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(!connected || validation.isBusy)
                if validation.isCapturing {
                    Button("Cancel + Keep Partial") { bench.cancelIREValidationCapture() }
                        .buttonStyle(DarkButtonStyle(destructive: true))
                        .disabled(validation.phase != .capturing)
                } else {
                    Button("2. Capture 300") { bench.startIREValidationCapture() }
                        .buttonStyle(DarkButtonStyle(prominent: true))
                        .disabled(
                            !connected || !bench.stream.isStreaming
                                || !validation.hasSession || validation.isBusy
                        )
                }
            }
            if validation.isBusy {
                ProgressView(
                    value: Double(validation.capturedFrames),
                    total: Double(IREValidationController.requiredFrameCount)
                )
                .tint(Theme.accent)
            }
        }
    }

    private func guidance(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number)
                .font(Theme.mono(9, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 12)
            Text("\(title): \(detail)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IREValidationOverlay: View {
    @ObservedObject var validation: IREValidationController
    let imageRect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawSelection(in: &context)
            }
            ForEach(Array(validation.selection.points.enumerated()), id: \.offset) { index, point in
                Text("\(index + 1)")
                    .font(Theme.mono(8, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.accent))
                    .position(displayPoint(point))
            }
        }
        .allowsHitTesting(false)
    }

    private func drawSelection(in context: inout GraphicsContext) {
        let points = validation.selection.points
        switch validation.subject {
        case .grayCard:
            if points.count == 2 {
                let a = displayPoint(points[0]), b = displayPoint(points[1])
                let rect = CGRect(
                    x: min(a.x, b.x),
                    y: min(a.y, b.y),
                    width: abs(a.x - b.x),
                    height: abs(a.y - b.y)
                )
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(Theme.accent),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                )
            }
        case .graySphere:
            if let center = points.first {
                let c = displayPoint(center)
                let radius = validation.selection.sphereOuterRadius * imageRect.width
                let outer = CGRect(x: c.x - radius, y: c.y - radius,
                                   width: radius * 2, height: radius * 2)
                let probeRadius = radius * 0.24
                let probe = CGRect(x: c.x - probeRadius, y: c.y - probeRadius,
                                   width: probeRadius * 2, height: probeRadius * 2)
                context.stroke(
                    Path(ellipseIn: outer),
                    with: .color(Theme.accent2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])
                )
                context.fill(Path(ellipseIn: probe), with: .color(Theme.accent.opacity(0.18)))
                context.stroke(Path(ellipseIn: probe), with: .color(Theme.accent),
                               lineWidth: 2)
            }
        case .colorChecker:
            guard let homography = IREChartHomography(corners: points) else { return }
            if let selected = homography.patchQuad(
                index: validation.selection.colorCheckerReferencePatch,
                insetFraction: 0.16
            ) {
                var highlight = Path()
                let display = selected.map { displayPoint($0) }
                if let first = display.first {
                    highlight.move(to: first)
                    for point in display.dropFirst() { highlight.addLine(to: point) }
                    highlight.closeSubpath()
                    context.fill(highlight, with: .color(Theme.accent.opacity(0.16)))
                }
            }
            var grid = Path()
            for column in 0...IREColorChecker.columns {
                let u = Double(column) / Double(IREColorChecker.columns)
                if let top = homography.project(u: u, v: 0),
                   let bottom = homography.project(u: u, v: 1) {
                    grid.move(to: displayPoint(top))
                    grid.addLine(to: displayPoint(bottom))
                }
            }
            for row in 0...IREColorChecker.rows {
                let v = Double(row) / Double(IREColorChecker.rows)
                if let left = homography.project(u: 0, v: v),
                   let right = homography.project(u: 1, v: v) {
                    grid.move(to: displayPoint(left))
                    grid.addLine(to: displayPoint(right))
                }
            }
            context.stroke(
                grid,
                with: .color(Theme.accent),
                style: StrokeStyle(lineWidth: 1.2, dash: [4, 2])
            )
        }
    }

    private func displayPoint(_ point: IRENormalizedPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }
}
