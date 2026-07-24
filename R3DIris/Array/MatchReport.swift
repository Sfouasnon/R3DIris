//  MatchReport.swift
//  R3DIris
//
//  End-of-set match report: a one-page PDF "contact sheet". One tile per camera
//  in ID order — the still (captured while the array is still in Log3G10, with
//  the matched overlays live) plus its IRE, delta-from-target, and match status —
//  above a summary strip (target, tolerance, array spread, timestamp).
//
//  Rendered from SwiftUI via ImageRenderer, so the tiles carry the same
//  jarvis-style styling as the live HUD. Must run on the main actor.

import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
import AppKit

// MARK: - Snapshot model (a frozen copy so rendering never races live state)

struct MatchReportCamera: Identifiable {
    let id: UUID
    let label: String          // GA, GB, …
    let ip: String
    let frame: CGImage?        // last livestream frame (Log3G10)
    let sphereCX: Double       // normalized 0…1 (r/w convention: r ÷ frame width)
    let sphereCY: Double
    let sphereR: Double
    let currentIRE: Double?
    let targetIRE: Double
    let deltaIRE: Double?
    let correctionStops: Double?
    let matched: Bool
}

struct MatchReportModel {
    let cameras: [MatchReportCamera]
    let targetIRE: Double
    let toleranceStops: Double
    let spreadStops: Double?
    let date: Date
}

// MARK: - Builder + writer

enum MatchReport {

    /// Snapshot the participants (ID-ordered) into a render-safe model. Call on
    /// the main actor BEFORE restoring the display transform.
    @MainActor
    static func model(cameras nodes: [CameraNode],
                      target: Double,
                      toleranceStops: Double,
                      spreadStops: Double?) -> MatchReportModel {
        let cams = nodes.map { node -> MatchReportCamera in
            MatchReportCamera(
                id: node.id,
                label: node.status.displayID.isEmpty ? node.ip : node.status.displayID,
                ip: node.ip,
                frame: node.stream.frame,
                sphereCX: node.sphere.cx,
                sphereCY: node.sphere.cy,
                sphereR: node.sphere.r,
                currentIRE: node.manualMatch.currentIRE ?? node.sphere.heroIRE,
                targetIRE: node.manualMatch.targetIRE ?? target,
                deltaIRE: node.manualMatch.deltaIRE,
                correctionStops: node.manualMatch.correctionStops,
                matched: node.manualMatch.phase == .matched)
        }
        return MatchReportModel(cameras: cams, targetIRE: target,
                                toleranceStops: toleranceStops,
                                spreadStops: spreadStops, date: Date())
    }

    /// Prompt for a location and write the one-page PDF. Returns the saved URL.
    @MainActor
    static func promptAndWrite(_ model: MatchReportModel) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stamp = ISO8601DateFormatter().string(from: model.date)
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "r3diris_match_report_\(stamp).pdf"
        panel.title = "Save Match Report"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return write(model, to: url) ? url : nil
    }

    /// Render the sheet to a single-page PDF at `url`.
    @MainActor
    @discardableResult
    static func write(_ model: MatchReportModel, to url: URL) -> Bool {
        let layout = SheetLayout(count: model.cameras.count)
        let renderer = ImageRenderer(
            content: ReportSheetView(model: model, layout: layout)
                .frame(width: layout.width, height: layout.height))
        renderer.proposedSize = .init(width: layout.width, height: layout.height)

        var ok = false
        renderer.render { size, renderInContext in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        return ok
    }
}

// MARK: - Layout

struct SheetLayout {
    let columns: Int
    let rows: Int
    let tileW: CGFloat = 360
    let tileH: CGFloat = 250     // 360×203 image area + label/data strip
    let gap: CGFloat = 14
    let margin: CGFloat = 22
    let headerH: CGFloat = 74

    init(count: Int) {
        columns = max(1, min(4, count))
        rows = max(1, Int(ceil(Double(count) / Double(columns))))
    }
    var width: CGFloat  { margin * 2 + CGFloat(columns) * tileW + CGFloat(columns - 1) * gap }
    var height: CGFloat { margin * 2 + headerH + CGFloat(rows) * tileH + CGFloat(rows - 1) * gap }
}

// MARK: - Sheet

struct ReportSheetView: View {
    let model: MatchReportModel
    let layout: SheetLayout

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: model.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            header
            let cols = Array(repeating: GridItem(.fixed(layout.tileW), spacing: layout.gap),
                             count: layout.columns)
            LazyVGrid(columns: cols, spacing: layout.gap) {
                ForEach(model.cameras) { cam in
                    ReportTileView(cam: cam, toleranceStops: model.toleranceStops)
                        .frame(width: layout.tileW, height: layout.tileH)
                }
            }
        }
        .padding(layout.margin)
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .background(Color(hex: 0x0d0e11))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("R3DIris — MATCH REPORT")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text(dateText)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer()
            summaryStat("TARGET", String(format: "%.0f IRE", model.targetIRE), Theme.ink)
            summaryStat("TOLERANCE", String(format: "±%.2f st", model.toleranceStops), Theme.ink2)
            summaryStat("ARRAY SPREAD",
                        model.spreadStops.map { String(format: "%.3f st", $0) } ?? "—",
                        (model.spreadStops ?? 0) <= model.toleranceStops ? Theme.good : Theme.warn)
            summaryStat("CAMERAS", "\(model.cameras.count)", Theme.ink2)
        }
        .frame(height: layout.headerH)
    }

    private func summaryStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(Theme.mono(9)).foregroundStyle(Theme.ink3)
            Text(value).font(Theme.mono(15, weight: .bold)).foregroundStyle(color)
        }
    }
}

// MARK: - Tile

struct ReportTileView: View {
    let cam: MatchReportCamera
    let toleranceStops: Double

    // Streams are 1920×1080 → fix the image box to 16:9 so the sphere ring maps
    // exactly with normalized coords (r_norm = r ÷ frame width).
    private let imageW: CGFloat = 360
    private var imageH: CGFloat { imageW * 9.0 / 16.0 }   // 202.5

    private var statusColor: Color {
        if cam.matched { return Theme.good }
        guard let c = cam.correctionStops else { return Theme.ink3 }
        return c > 0 ? Theme.warn : Theme.danger   // OPEN needs light / CLOSE too hot
    }
    private var statusText: String {
        if cam.matched { return "MATCHED" }
        guard let c = cam.correctionStops else { return "NO SIGNAL" }
        return String(format: "%@ %.2f st", c > 0 ? "OPEN" : "CLOSE", abs(c))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                imageArea
                // Camera ID chip
                Text(cam.label)
                    .font(Theme.mono(13, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                    .padding(7)
                // Big IRE readout (jarvis)
                VStack(alignment: .trailing, spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(cam.currentIRE.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(statusColor)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                        Text("IRE")
                            .font(Theme.mono(10, weight: .bold))
                            .foregroundStyle(Theme.ink2)
                            .padding(.bottom, 5)
                    }
                }
                .padding(9)
            }
            .frame(width: imageW, height: imageH)
            .clipped()

            dataStrip
        }
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm)
            .stroke(statusColor.opacity(0.55), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
    }

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let frame = cam.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Text("no frame").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                }
                // Sphere ring at the frozen ROI (r_norm = r ÷ frame width).
                let d = CGFloat(cam.sphereR) * geo.size.width * 2
                Circle()
                    .stroke(statusColor.opacity(0.9), lineWidth: 2)
                    .frame(width: d, height: d)
                    .position(x: CGFloat(cam.sphereCX) * geo.size.width,
                              y: CGFloat(cam.sphereCY) * geo.size.height)
            }
        }
    }

    private var dataStrip: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(Theme.mono(12, weight: .bold))
                .foregroundStyle(statusColor)
            Spacer()
            Text(String(format: "Δ %+.1f IRE", cam.deltaIRE ?? 0))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
            Text("→ \(String(format: "%.0f", cam.targetIRE))")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
