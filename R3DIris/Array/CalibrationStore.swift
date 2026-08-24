//  CalibrationStore.swift — R3DIris / Array
//  Persistence for the Calibrate workflow: the pinned reference IRE and the
//  accumulating calibration roll.
//
//  This is the project's first and only persistence layer, and it exists for
//  exactly one reason: a 36-body integrating-sphere run cannot hold its
//  reference number in memory. The target is established on camera 1 and every
//  camera after it trims to that same value — across app restarts, across days.
//
//  Rows are written the instant a camera certifies, not at the end of the run,
//  so a crash at camera 28 costs nothing but camera 28.
//
//  Layout:
//    ~/Library/Application Support/R3DIris/calibration.json
//    ~/Library/Application Support/R3DIris/roll/<displayID>.png

import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// The reference IRE every camera in a set is trimmed to.
///
/// `transform` is not decoration. An IRE measured through Log3G10 means
/// something different through IPP2, so the value carries the monitoring
/// transform it was captured under and the session refuses to apply it under
/// any other one.
struct PinnedTarget: Codable, Equatable {
    var ire: Double
    /// ArrayController.ManualTransform.rawValue at capture time.
    var transform: String
    var capturedAt: Date
    /// displayID of the camera that established it — provenance on the roll.
    var sourceCameraID: String
    var toleranceStops: Double
}

/// One certified camera in the run.
struct CalibrationRollRow: Codable, Equatable, Identifiable {
    /// displayID is the identity: re-calibrating a body REPLACES its row rather
    /// than appending a second one.
    var displayID: String
    var ip: String
    var serial: String
    var finalIRE: Double
    var targetIRE: Double
    var deltaIRE: Double
    var correctionStops: Double
    /// Lens T-stop at certification ("5.6"), or "N/A" with no lens data.
    var stopLabel: String
    var certifiedAt: Date
    /// Filename (not path) of the PNG still inside the roll directory.
    var stillFilename: String
    /// Frozen sphere ROI, normalized exactly as SphereState stores it
    /// (cx = x/width, cy = y/height, r = radius/width) so the roll report can
    /// draw the same measurement ring the live HUD showed.
    var sphereCX: Double
    var sphereCY: Double
    var sphereR: Double

    var id: String { displayID }
}

private struct CalibrationDocument: Codable {
    var pin: PinnedTarget?
    var roll: [CalibrationRollRow]
}

/// File-backed store. Every mutation writes through immediately — there is no
/// flush-on-quit, because the failure this guards against is not a clean quit.
final class CalibrationStore {

    private let fileManager = FileManager.default

    /// ~/Library/Application Support/R3DIris
    private var directory: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("R3DIris", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var documentURL: URL? {
        directory?.appendingPathComponent("calibration.json")
    }

    /// Directory holding the per-camera PNG stills.
    var rollDirectory: URL? {
        guard let dir = directory else { return nil }
        let roll = dir.appendingPathComponent("roll", isDirectory: true)
        try? fileManager.createDirectory(at: roll, withIntermediateDirectories: true)
        return roll
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Read

    /// Load the persisted state. A missing or unreadable file is not an error —
    /// it simply means no run has started yet.
    func load() -> (pin: PinnedTarget?, roll: [CalibrationRollRow]) {
        guard let url = documentURL,
              let data = try? Data(contentsOf: url),
              let doc = try? decoder.decode(CalibrationDocument.self, from: data) else {
            return (nil, [])
        }
        return (doc.pin, doc.roll)
    }

    // MARK: - Write

    @discardableResult
    private func save(pin: PinnedTarget?, roll: [CalibrationRollRow]) -> Bool {
        guard let url = documentURL else { return false }
        let doc = CalibrationDocument(pin: pin, roll: roll)
        guard let data = try? encoder.encode(doc) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func savePin(_ pin: PinnedTarget?, roll: [CalibrationRollRow]) -> Bool {
        save(pin: pin, roll: roll)
    }

    @discardableResult
    func saveRoll(_ roll: [CalibrationRollRow], pin: PinnedTarget?) -> Bool {
        save(pin: pin, roll: roll)
    }

    /// Write a certified camera's still as a PNG beside the document. Returns
    /// the bare filename to store on the row, or nil if there was no frame.
    func writeStill(_ image: CGImage?, displayID: String) -> String? {
        guard let image, let dir = rollDirectory else { return nil }
        let cleaned = displayID.filter { $0.isLetter || $0.isNumber }
        let safe = cleaned.isEmpty ? "camera" : cleaned
        let filename = "\(safe).png"
        let url = dir.appendingPathComponent(filename)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    /// Read a row's still back for report rendering.
    func loadStill(_ filename: String) -> CGImage? {
        guard let dir = rollDirectory else { return nil }
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    /// Delete every still. Called only when the operator clears the roll.
    func deleteStills() {
        guard let dir = rollDirectory,
              let contents = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.pathExtension.lowercased() == "png" {
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: - Roll helpers

extension Array where Element == CalibrationRollRow {
    /// Insert or replace by displayID, keeping the roll in ID order. A re-trim
    /// of an already-recorded body overwrites its row — the roll always shows
    /// each camera exactly once, in its final state.
    mutating func upsert(_ row: CalibrationRollRow) {
        if let index = firstIndex(where: { $0.displayID == row.displayID }) {
            self[index] = row
        } else {
            append(row)
        }
        sort { $0.displayID < $1.displayID }
    }

    /// Spread across the whole recorded set, in stops. nil below two rows.
    var spreadStops: Double? {
        let ires = map(\.finalIRE).sorted()
        guard let lo = ires.first, let hi = ires.last, ires.count >= 2 else { return nil }
        let spread = abs(Log3G10.stops(between: lo, and: hi))
        return spread.isFinite ? spread : nil
    }
}
