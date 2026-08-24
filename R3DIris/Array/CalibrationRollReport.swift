//  CalibrationRollReport.swift — R3DIris / Array
//  The end-of-run deliverable for the Calibrate workflow: one paginated PDF
//  covering every camera in the set.
//
//  MatchReport renders a single session's array onto one page. A 36-body
//  integrating-sphere run is a different shape — the cameras were never on the
//  bench at the same time, and 36 tiles on one page is a 2270 pt sheet nobody
//  can print. So this report leads with a summary page (the reference, its
//  provenance, and the spread across the whole set) and then lays the stills
//  out 16 to a page.
//
//  Tiles are rendered by MatchReport's ReportTileView so a roll page and a
//  match report page look like the same document.

import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
import AppKit

// MARK: - Model

struct CalibrationRollModel {
    let rows: [CalibrationRollRow]
    /// Stills loaded off disk, keyed by displayID. Loaded once up front so
    /// rendering never touches the filesystem mid-page.
    let stills: [String: CGImage]
    let pin: PinnedTarget?
    /// Monitoring transform in force when the report was taken.
    let transform: String
    let toleranceStops: Double
    let spreadStops: Double?
    let date: Date

    var inTolerance: Int {
        rows.filter { abs($0.correctionStops) <= toleranceStops }.count
    }
}

// MARK: - Layout

struct RollSheetLayout {
    let tileW: CGFloat = 360
    let tileH: CGFloat = 250
    let gap: CGFloat = 14
    let margin: CGFloat = 22
    let headerH: CGFloat = 74
    let columns = 4
    let rows = 4

    var tilesPerPage: Int { columns * rows }
    /// Table rows on a summary page. Kept under the page height so a set larger
    /// than one table page simply continues onto another.
    let tableRowsPerPage = 32

    var width: CGFloat {
        margin * 2 + CGFloat(columns) * tileW + CGFloat(columns - 1) * gap
    }
    var height: CGFloat {
        margin * 2 + headerH + gap + CGFloat(rows) * tileH + CGFloat(rows - 1) * gap
    }
}

// MARK: - Builder + writer

enum CalibrationRollReport {

    /// Snapshot the roll into a render-safe model, loading each still off disk.
    @MainActor
    static func model(rows: [CalibrationRollRow],
                      pin: PinnedTarget?,
                      transform: String,
                      toleranceStops: Double,
                      store: CalibrationStore) -> CalibrationRollModel {
        var stills: [String: CGImage] = [:]
        for row in rows where !row.stillFilename.isEmpty {
            if let image = store.loadStill(row.stillFilename) {
                stills[row.displayID] = image
            }
        }
        return CalibrationRollModel(
            rows: rows,
            stills: stills,
            pin: pin,
            transform: transform,
            toleranceStops: toleranceStops,
            spreadStops: rows.spreadStops,
            date: Date()
        )
    }

    @MainActor
    static func promptAndWrite(_ model: CalibrationRollModel) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stamp = ISO8601DateFormatter().string(from: model.date)
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "r3diris_calibration_roll_\(stamp).pdf"
        panel.title = "Save Calibration Roll"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return write(model, to: url) ? url : nil
    }

    /// Render the whole run to a multi-page PDF.
    @MainActor
    @discardableResult
    static func write(_ model: CalibrationRollModel, to url: URL) -> Bool {
        let layout = RollSheetLayout()
        var box = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }

        var wroteAnyPage = false

        // Page(s) 1…n: the summary table.
        let tableChunks = model.rows.isEmpty
            ? [[CalibrationRollRow]()]
            : model.rows.chunked(into: layout.tableRowsPerPage)
        for (index, chunk) in tableChunks.enumerated() {
            let page = RollSummaryPage(model: model, layout: layout,
                                       rows: chunk, pageIndex: index,
                                       pageCount: tableChunks.count)
            if renderPage(page, layout: layout, into: ctx) { wroteAnyPage = true }
        }

        // Page(s) n+1…: the stills, 16 to a page.
        let tileChunks = model.rows.chunked(into: layout.tilesPerPage)
        for (index, chunk) in tileChunks.enumerated() {
            let page = RollTilePage(model: model, layout: layout,
                                    rows: chunk, pageIndex: index,
                                    pageCount: tileChunks.count)
            if renderPage(page, layout: layout, into: ctx) { wroteAnyPage = true }
        }

        ctx.closePDF()
        return wroteAnyPage
    }

    @MainActor
    private static func renderPage<Page: View>(_ page: Page,
                                               layout: RollSheetLayout,
                                               into ctx: CGContext) -> Bool {
        let renderer = ImageRenderer(
            content: page.frame(width: layout.width, height: layout.height))
        renderer.proposedSize = .init(width: layout.width, height: layout.height)
        var ok = false
        renderer.render { _, renderInContext in
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ok = true
        }
        return ok
    }
}

// MARK: - Summary page

struct RollSummaryPage: View {
    let model: CalibrationRollModel
    let layout: RollSheetLayout
    let rows: [CalibrationRollRow]
    let pageIndex: Int
    let pageCount: Int

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private var targetText: String {
        if let pin = model.pin { return String(format: "%.2f IRE", pin.ire) }
        guard let first = rows.first ?? model.rows.first else { return "—" }
        return String(format: "%.2f IRE", first.targetIRE)
    }

    private var provenanceText: String {
        guard let pin = model.pin else { return "not pinned" }
        let who = pin.sourceCameraID.isEmpty ? "—" : pin.sourceCameraID
        return "pinned from \(who) · \(pin.transform) · \(Self.stamp.string(from: pin.capturedAt))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            header
            table
            Spacer(minLength: 0)
        }
        .padding(layout.margin)
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .background(Color(hex: 0x0d0e11))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("R3DIris — CALIBRATION ROLL")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text("\(Self.stamp.string(from: model.date))  ·  \(provenanceText)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer()
            stat("TARGET", targetText, Theme.ink)
            stat("TOLERANCE", String(format: "±%.2f st", model.toleranceStops), Theme.ink2)
            stat("SET SPREAD",
                 model.spreadStops.map { String(format: "%.3f st", $0) } ?? "—",
                 (model.spreadStops ?? 0) <= model.toleranceStops ? Theme.good : Theme.warn)
            stat("IN TOL", "\(model.inTolerance)/\(model.rows.count)",
                 model.inTolerance == model.rows.count ? Theme.good : Theme.warn)
        }
        .frame(height: layout.headerH)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(Theme.mono(9)).foregroundStyle(Theme.ink3)
            Text(value).font(Theme.mono(15, weight: .bold)).foregroundStyle(color)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            tableHeaderRow
            ForEach(rows.indices, id: \.self) { index in
                tableRow(rows[index], alternate: index.isMultiple(of: 2))
            }
            if pageCount > 1 {
                HStack {
                    Spacer()
                    Text("summary \(pageIndex + 1)/\(pageCount)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.top, 6)
            }
        }
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 0) {
            cell("CAMERA", width: 90, align: .leading)
            cell("IP", width: 150, align: .leading)
            cell("SERIAL", width: 190, align: .leading)
            cell("STOP", width: 90, align: .trailing)
            cell("IRE", width: 110, align: .trailing)
            cell("Δ IRE", width: 110, align: .trailing)
            cell("Δ STOPS", width: 120, align: .trailing)
            cell("CERTIFIED", width: 200, align: .trailing)
            Spacer(minLength: 0)
        }
        .font(Theme.mono(10, weight: .bold))
        .foregroundStyle(Theme.ink3)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line2).frame(height: 1)
        }
    }

    private func tableRow(_ row: CalibrationRollRow, alternate: Bool) -> some View {
        let ok = abs(row.correctionStops) <= model.toleranceStops
        return HStack(spacing: 0) {
            cell(row.displayID, width: 90, align: .leading, color: Theme.ink)
            cell(row.ip, width: 150, align: .leading)
            cell(row.serial.isEmpty ? "—" : row.serial, width: 190, align: .leading)
            cell(row.stopLabel, width: 90, align: .trailing)
            cell(String(format: "%.2f", row.finalIRE), width: 110, align: .trailing, color: Theme.ink)
            cell(String(format: "%+.2f", row.deltaIRE), width: 110, align: .trailing)
            cell(String(format: "%+.3f", row.correctionStops), width: 120, align: .trailing,
                 color: ok ? Theme.good : Theme.warn)
            cell(Self.stamp.string(from: row.certifiedAt), width: 200, align: .trailing)
            Spacer(minLength: 0)
        }
        .font(Theme.mono(10.5))
        .foregroundStyle(Theme.ink2)
        .padding(.vertical, 6)
        .background(alternate ? Theme.panel2 : Color.clear)
    }

    private func cell(_ text: String, width: CGFloat,
                      align: Alignment, color: Color? = nil) -> some View {
        Text(text)
            .foregroundStyle(color ?? Theme.ink2)
            .frame(width: width, alignment: align)
            .padding(.horizontal, 6)
            .lineLimit(1)
    }
}

// MARK: - Tile page

struct RollTilePage: View {
    let model: CalibrationRollModel
    let layout: RollSheetLayout
    let rows: [CalibrationRollRow]
    let pageIndex: Int
    let pageCount: Int

    /// Bridge a stored roll row into the shared tile view. `matched` is derived
    /// from the recorded correction rather than live state — the camera is long
    /// gone by the time this renders.
    private func tile(for row: CalibrationRollRow) -> MatchReportCamera {
        MatchReportCamera(
            id: UUID(),
            label: row.displayID,
            ip: row.ip,
            frame: model.stills[row.displayID],
            sphereCX: row.sphereCX,
            sphereCY: row.sphereCY,
            sphereR: row.sphereR,
            currentIRE: row.finalIRE,
            targetIRE: row.targetIRE,
            deltaIRE: row.deltaIRE,
            correctionStops: row.correctionStops,
            matched: abs(row.correctionStops) <= model.toleranceStops
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            header
            let cols = Array(
                repeating: GridItem(.fixed(layout.tileW), spacing: layout.gap),
                count: layout.columns)
            LazyVGrid(columns: cols, spacing: layout.gap) {
                ForEach(rows) { row in
                    ReportTileView(cam: tile(for: row),
                                   toleranceStops: model.toleranceStops)
                        .frame(width: layout.tileW, height: layout.tileH)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(layout.margin)
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .background(Color(hex: 0x0d0e11))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("R3DIris — CALIBRATION ROLL")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text("stills \(pageIndex + 1)/\(pageCount)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TARGET").font(Theme.mono(9)).foregroundStyle(Theme.ink3)
                Text(model.rows.first.map { String(format: "%.2f IRE", $0.targetIRE) } ?? "—")
                    .font(Theme.mono(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(height: layout.headerH)
    }
}

// MARK: - Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
