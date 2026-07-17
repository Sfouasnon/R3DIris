//  RCP2.swift — R3DIris / RCP2Core
//  Protocol constants and message-parsing helpers.
//
//  Adapted from REDConductorV3's transport (read-only reference; V3 is the
//  proven implementation — divergences here must be deliberate). Every rule
//  number traces to RCP2_FIELD_NOTES.md; aperture/livestream specifics trace
//  to RCP2_APERTURE_NOTES.md and RCP2_LIVESTREAM_NOTES.md (repo root).
//
//  NOTE: SYNC_RECORD_* params are pre-release firmware params supplied
//  privately by a RED engineer — not public-facing. R3DIris does not use them,
//  but keep any mention out of shipped UI/logs regardless.

import Foundation

enum RCP2 {
    static let wsPort: UInt16 = 9998
    static let livestreamPort: UInt16 = 9090   // multipart-HTTP JPEG (LIVESTREAM_NOTES)
    static let clientName = "R3DIris"
    static let clientVersion = "0.1"

    // Field notes rule 9 — the ONLY params kept subscribed at steady state.
    // The spike needs almost nothing pushed: TIMECODE is the 1/s liveness
    // signal; RECORD_STATE is the no-residue heartbeat param (rule 7).
    // APERTURE is subscribed separately by the operator via the bench gate —
    // it is NOT here until rule-11 benching proves it safe on FW 2.2.4.
    static let subscribedParams: [String] = [
        "RECORD_STATE", "TIMECODE",
    ]

    // Aperture params (RCP2_APERTURE_NOTES.md). ALL # UNVERIFIED on a body.
    // Only ever touched through deliberate, operator-triggered bench actions —
    // never automatically (rule 11: a blind `rcp_get ISO` wedged a session).
    static let apertureParam = "APERTURE"                 // rcp_set value = stop ×10 (56 = 5.6)
    static let apertureControlParam = "APERTURE_CONTROL"  // 0 NOT_SUPPORTED / 1 SUPPORTED — the e-iris gate
    static let apertureListModeParam = "APERTURE_LIST_MODE" // 0 = 1/4-stop, 1 = 1/3-stop increments
    static let aeModeParam = "AE_MODE"                    // != OFF and !AE_LOCK_APERTURE → AE owns the iris
    static let aeLockApertureParam = "AE_LOCK_APERTURE"

    // Livestream params (RCP2_LIVESTREAM_NOTES.md). ALL # UNVERIFIED on a body.
    static let livestreamEnableParam = "LIVESTREAM_ENABLE"          // 0/1, settable
    static let livestreamQualityParam = "LIVESTREAM_QUALITY"        // 1=Q25 2=Q50 3=Q75 4=Q100
    static let livestreamMirrorSourceParam = "LIVESTREAM_MIRROR_SOURCE" // status: 0 none 1 SDI-1 2 SDI-2 3 top LCD
    static let livestreamRectPixelsParam = "LIVESTREAM_RECT_PIXELS"     // status: sensor→stream mapping

    // Monitor-output viewing-transform params (RCP2_TRANSFORM_NOTES.md).
    // ALL # UNVERIFIED on a body and therefore touched only by deliberate
    // operator actions (rule 11). These are output-side display presets, not
    // record-side COLOR_SPACE / GAMMA_SPACE image-pipeline controls.
    static let displayPresetSDI1Param = "DISPLAY_PRESET_SDI_1"
    static let displayPresetSDI2Param = "DISPLAY_PRESET_SDI_2"
    static let displayPresetBuiltInLCDParam = "DISPLAY_PRESET_BUILT_IN_LCD"
    static let displayPresetDSI1Param = "DISPLAY_PRESET_DSI_1"
    static let displayPresetImageLUTParam = "DISPLAY_PRESET_IMAGE_LUT"
    static let log3G10DisplayPresetValue = 0

    static let monitorDisplayPresetParams: Set<String> = [
        displayPresetSDI1Param,
        displayPresetSDI2Param,
        displayPresetBuiltInLCDParam,
        displayPresetDSI1Param,
        displayPresetImageLUTParam,
    ]

    // Params we may rcp_get even when the camera doesn't advertise a param list
    // (KOMODO-X FW 2.2.4 advertises none). Everything else requires advertisement
    // — blind gets have been observed to wedge the RCP2 session (rule 11).
    // Aperture/livestream params are deliberately NOT in this set: the bench UI
    // must pass allowUnadvertised explicitly, so every first touch is a logged,
    // conscious act on a sacrificial session.
    static let coreParams: Set<String> = Set(subscribedParams)

    static let recordStateLabels: [Int: String] = [
        0: "IDLE", 1: "RECORDING", 2: "FINALIZING",
        3: "PRE_RECORDING", 4: "ENCODING", 5: "SYNC_ARMED",
    ]

    static let mirrorSourceLabels: [Int: String] = [
        0: "NONE", 1: "SDI-1", 2: "SDI-2", 3: "TOP LCD",
    ]

    static let livestreamQualityLabels: [Int: String] = [
        1: "Q25", 2: "Q50", 3: "Q75", 4: "Q100",
    ]

    static let displayPresetLabels: [Int: String] = [
        0: "LOG3G10", 1: "HDR", 2: "HDR 400", 3: "HDR 1K",
        4: "HDR 2K", 5: "HDR 4K", 6: "SDR", 7: "HLG",
    ]

    /// Resolve the output preset that actually feeds the livestream mirror.
    /// LIVESTREAM_MIRROR_SOURCE: 1 SDI-1, 2 SDI-2, 3 built-in/top LCD.
    static func monitorDisplayPresetParam(forMirrorSource source: Int?) -> String? {
        monitorDisplayPresetCandidates(forMirrorSource: source).first
    }

    /// TOP LCD is DISPLAY_PRESET_BUILT_IN_LCD on KOMODO-X and
    /// DISPLAY_PRESET_DSI_1 on V-RAPTOR/XL. Prefer the parameter advertised by
    /// the body; KOMODO-X FW 2.2.4's known empty-list behavior falls back to
    /// BUILT_IN_LCD. See RCP2_TRANSFORM_NOTES.md.
    static func monitorDisplayPresetCandidates(forMirrorSource source: Int?) -> [String] {
        switch source {
        case 1: return [displayPresetSDI1Param]
        case 2: return [displayPresetSDI2Param]
        case 3: return [displayPresetBuiltInLCDParam, displayPresetDSI1Param]
        default: return []
        }
    }

    // MARK: Aperture value helpers (encoding: stop ×10; ≤0 = N/A / no lens data)

    /// 56 -> "5.6", 110 -> "11". Display semantics per 910-0315: the value is
    /// the lens T-stop when available, else F-stop — label it generically.
    static func stopLabel(_ x10: Int?) -> String {
        guard let x10, x10 > 0 else { return "N/A" }
        let whole = x10 / 10, tenth = x10 % 10
        return tenth == 0 ? "\(whole)" : "\(whole).\(tenth)"
    }

    // MARK: Message helpers (RCP2 JSON is loosely shaped — parse defensively)

    static func normParamID(_ value: Any?) -> String {
        var text = (value as? String ?? "").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("RCP_PARAM_") { text.removeFirst("RCP_PARAM_".count) }
        return text
    }

    /// Extract a display string from any RCP2 message shape (rcp_cur_str,
    /// rcp_cur_tc, …). Match on content, not wrapper type (field notes, init §).
    static func extractDisplay(_ msg: [String: Any]?) -> String {
        guard let msg else { return "" }

        func pick(_ obj: Any?) -> String {
            if let dict = obj as? [String: Any] {
                for key in ["str", "display", "name", "label", "abbr", "val", "value", "cur"] {
                    if let inner = dict[key] {
                        let text = pick(inner)
                        if !text.isEmpty { return text }
                    }
                }
                return ""
            }
            if let s = obj as? String { return s }
            if let b = obj as? Bool { return b ? "1" : "0" }
            if let i = obj as? Int { return String(i) }
            if let d = obj as? Double { return String(d) }
            return ""
        }

        for key in ["display", "cur", "value", "str"] {
            let text = pick(msg[key])
            if !text.isEmpty { return text }
        }
        return ""
    }

    static func extractInt(_ msg: [String: Any]?) -> Int? {
        guard let msg else { return nil }

        func pick(_ obj: Any?) -> Int? {
            if let b = obj as? Bool { return b ? 1 : 0 }
            if let i = obj as? Int { return i }
            if let d = obj as? Double { return Int(d) }
            if let s = obj as? String {
                let v = s.trimmingCharacters(in: .whitespaces)
                return Int(v)
            }
            if let dict = obj as? [String: Any] {
                for key in ["val", "value", "cur", "display", "str"] {
                    if let inner = dict[key], let found = pick(inner) { return found }
                }
            }
            return nil
        }

        for key in ["cur", "value", "display", "str"] {
            if let inner = msg[key], let found = pick(inner) { return found }
        }
        return pick(msg)
    }

    /// APERTURE is a value-with-target param: `rcp_cur_int` carries both
    /// cur.val (where the iris IS) and target.val (where it's been told to go).
    /// cur == target is the loop's settle detector (APERTURE_NOTES "The SET").
    static func extractCurTarget(_ msg: [String: Any]?) -> (cur: Int?, target: Int?) {
        guard let msg else { return (nil, nil) }
        func val(_ obj: Any?) -> Int? {
            if let i = obj as? Int { return i }
            if let d = obj as? Double { return Int(d) }
            if let dict = obj as? [String: Any] {
                for key in ["val", "value"] {
                    if let inner = dict[key] { return val(inner) }
                }
            }
            if let s = obj as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        return (val(msg["cur"]), val(msg["target"]))
    }

    /// Extract a list payload (rcp_cur_list) as ints — used for
    /// `rcp_get_list APERTURE` (the mounted lens's valid stop values ×10).
    static func extractIntList(_ msg: [String: Any]?) -> [Int] {
        guard let msg else { return [] }
        func val(_ obj: Any?) -> Int? {
            if let i = obj as? Int { return i }
            if let d = obj as? Double { return Int(d) }
            if let dict = obj as? [String: Any] {
                for key in ["val", "value", "num"] {
                    if let inner = dict[key], let found = val(inner) { return found }
                }
            }
            if let s = obj as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        for key in ["list", "values", "data", "cur"] {
            if let arr = msg[key] as? [Any] {
                let ints = arr.compactMap { val($0) }
                if !ints.isEmpty { return ints }
            }
        }
        return []
    }

    /// True for a real HH:MM:SS(:|;FF) timecode — guards against placeholder junk.
    static func looksLikeTC(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^\d{1,2}:\d{2}:\d{2}(?:[:;]\d{2})?$"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }
}
