//  Models.swift — R3DIris core value types.

import Foundation

enum LinkState: String, Sendable {
    case disconnected   // not running / never connected
    case connecting     // run loop active, session not initialized
    case connected      // session initialized + subscribed
    case parked         // gave up after repeated failures; revives on operator Refresh
}

/// Viewing transform on the monitor output mirrored into the :9090 stream.
/// Every value remains # UNVERIFIED until RCP2_TRANSFORM_NOTES.md's bench
/// checklist passes on a real body.
enum MonitorTransformState: String, Sendable, Equatable {
    case log3G10 = "LOG3G10"
    case ipp2 = "IPP2"
    case unknown = "UNKNOWN"
}

struct MonitorTransformReading: Sendable, Equatable {
    var mirrorSource: Int? = nil
    var parameterID: String = ""
    var presetValue: Int? = nil

    var state: MonitorTransformState {
        guard let presetValue else { return .unknown }
        return presetValue == RCP2.log3G10DisplayPresetValue ? .log3G10 : .ipp2
    }
}

/// Live status for the one benched camera (published by CameraActor, rendered
/// by UI). Phase 0 is single-body; the array version arrives in Phase 2.
struct CameraStatus: Sendable, Equatable {
    var link: LinkState = .disconnected
    var lastError: String = ""

    // Identity (from CAMERA_INFO)
    var name: String = ""
    var serial: String = ""
    var firmware: String = ""

    // Liveness
    var currentTC: String = ""
    var tcSeenAt: Date? = nil
    var recordState: Int = 0

    // Aperture (RCP2_APERTURE_NOTES.md — all values are stop ×10; nil = never seen)
    var apertureCur: Int? = nil
    var apertureTarget: Int? = nil
    var apertureSeenAt: Date? = nil
    var apertureList: [Int] = []        // valid stops for the mounted lens (rcp_get_list)
    var apertureControl: Int? = nil     // 0 NOT_SUPPORTED / 1 SUPPORTED (e-iris gate)
    var apertureListMode: Int? = nil    // 0 = 1/4-stop, 1 = 1/3-stop
    var aeMode: Int? = nil              // != 0 (and !aeLock) → AE owns the iris
    var aeLockAperture: Int? = nil

    // Livestream (RCP2_LIVESTREAM_NOTES.md)
    var livestreamEnabled: Int? = nil
    var livestreamQuality: Int? = nil   // 1=Q25 2=Q50 3=Q75 4=Q100
    var mirrorSource: Int? = nil        // 0 none / 1 SDI-1 / 2 SDI-2 / 3 top LCD
    var rectPixels: String = ""         // raw sensor→stream mapping payload, verbatim

    // Monitor-output preset feeding the livestream mirror
    // (RCP2_TRANSFORM_NOTES.md; all # UNVERIFIED on hardware).
    var monitorTransformParam: String = ""
    var monitorTransformValue: Int? = nil
    var monitorTransformSeenAt: Date? = nil

    var monitorTransform: MonitorTransformState {
        guard let monitorTransformValue else { return .unknown }
        return monitorTransformValue == RCP2.log3G10DisplayPresetValue ? .log3G10 : .ipp2
    }

    /// TC lock = a timecode push landed recently (KOMODO pushes TC at 1/s).
    var tcLock: Bool {
        guard let seen = tcSeenAt else { return false }
        return link == .connected && Date().timeIntervalSince(seen) <= 2.5
    }

    /// Settle detector: the iris has reached where it was told to go
    /// (APERTURE cur == target — value-with-target semantics).
    var apertureSettled: Bool {
        guard let c = apertureCur, let t = apertureTarget else { return false }
        return c == t
    }

    var recordStateLabel: String {
        RCP2.recordStateLabels[recordState] ?? "STATE \(recordState)"
    }
}

/// One timestamped bench-log line. The log IS the deliverable of Phase 0 —
/// every finding feeds RCP2_APERTURE_NOTES / RCP2_LIVESTREAM_NOTES.
struct BenchLogLine: Identifiable, Sendable {
    let id = UUID()
    let date = Date()
    let text: String
}
