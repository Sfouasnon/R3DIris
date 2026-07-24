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
    // CLIP_NAME_2 / CLIP_NAME do NOT support rcp_subscribe (Status, get-only per
    // the KOMODO-X PDF) — the identifier is fetched with an explicit get at
    // connect instead. Only genuinely push-capable params belong here.
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

    // Livestream params (RCP2_LIVESTREAM_NOTES.md). Bench-verified on a body.
    static let livestreamEnableParam = "LIVESTREAM_ENABLE"          // 0/1, settable
    static let livestreamQualityParam = "LIVESTREAM_QUALITY"        // 1=Q25 2=Q50 3=Q75 4=Q100
    static let cameraIDParam = "CAMERA_ID"                          // param 42 — user identifier "GA" (rcp_cur_str/int)
    static let livestreamMirrorSourceParam = "LIVESTREAM_MIRROR_SOURCE" // status: 0 none 1 SDI-1 2 SDI-2 3 top LCD
    static let livestreamRectPixelsParam = "LIVESTREAM_RECT_PIXELS"     // status: sensor→stream mapping

    // Monitor-output viewing-transform params (RCP2_TRANSFORM_NOTES.md).
    // Bench-verified; still touched only by deliberate operator actions
    // (rule 11). These are output-side display presets, not record-side
    // COLOR_SPACE / GAMMA_SPACE image-pipeline controls.
    static let displayPresetSDI1Param = "DISPLAY_PRESET_SDI_1"
    static let displayPresetSDI2Param = "DISPLAY_PRESET_SDI_2"
    static let displayPresetBuiltInLCDParam = "DISPLAY_PRESET_BUILT_IN_LCD"
    static let displayPresetDSI1Param = "DISPLAY_PRESET_DSI_1"
    static let displayPresetImageLUTParam = "DISPLAY_PRESET_IMAGE_LUT"
    // The "Look" that selects Log3G10 monitoring is SDI_COLOR_SETTING per output,
    // NOT DISPLAY_PRESET_* (that is a Custom-Display sub-setting). COLOR_SETTING_LOG=0
    // is RWG/Log3G10; 1=3D LUT, 2=Custom Display are display-rendered looks. The
    // mirrored output feeds the livestream, so this is what makes the analyzed
    // stream carry Log3G10.
    //
    // Confirmed 2026-07-21 by decoding a RED Control Pro packet capture (rcp_look
    // .pcap): swapping an output's Look writes exactly ONE param — that output's
    // SDI_COLOR_SETTING — cycling 0/1/2. RCP never touched DISPLAY_PRESET to reach
    // Log3G10 (it only moved while the Look was Custom Display). SDI-1's Look is the
    // BARE `SDI_COLOR_SETTING` on KOMODO/KOMODO-X/V-RAPTOR — there is no
    // `SDI_COLOR_SETTING_SDI_1` (that non-existent name is what the camera refused
    // under rule 11 in the 2026-07-20 bench log).
    static let sdiColorSettingParam = "SDI_COLOR_SETTING"              // SDI-1 (bare)
    static let sdiColorSettingSDI2Param = "SDI_COLOR_SETTING_SDI_2"    // V-RAPTOR only
    static let sdiColorSettingBuiltInLCDParam = "SDI_COLOR_SETTING_BUILT_IN_LCD" // onboard LCD
    static let sdiColorSettingDSI1Param = "SDI_COLOR_SETTING_DSI_1"    // top-port monitor
    // Log3G10 = COLOR_SETTING_LOG (0). (Name kept; the transform code compares
    // the active mirror output's COLOR_SETTING against this.)
    static let log3G10DisplayPresetValue = 0

    // The params the transform layer is allowed to set (the SDI_COLOR_SETTING
    // "Look" family — Log3G10 lives here, not in DISPLAY_PRESET).
    static let monitorDisplayPresetParams: Set<String> = [
        sdiColorSettingParam,
        sdiColorSettingSDI2Param,
        sdiColorSettingBuiltInLCDParam,
        sdiColorSettingDSI1Param,
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

    // COLOR_SETTING "Look" enum (KOMODO-X PDF, SDI_COLOR_SETTING_* TYPES block).
    static let displayPresetLabels: [Int: String] = [
        0: "LOG3G10", 1: "3D LUT", 2: "CUSTOM DISPLAY",
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
        // TOP LCD (mirror source 3) is the DSMC3 top-port monitor = DSI_1, which
        // the PDF/SDK name distinctly from the onboard LCD (BUILT_IN_LCD). Prefer
        // DSI_1; fall back to BUILT_IN_LCD only if DSI_1 isn't advertised.
        // [confirm-on-bench: exact source-3 → DSI_1 link rests on the SDK label.]
        switch source {
        case 1: return [sdiColorSettingParam]                                   // SDI-1 (bare)
        case 2: return [sdiColorSettingSDI2Param]                               // V-RAPTOR only
        case 3: return [sdiColorSettingDSI1Param, sdiColorSettingBuiltInLCDParam] // top-port, then onboard
        default: return [sdiColorSettingParam, sdiColorSettingDSI1Param, sdiColorSettingBuiltInLCDParam]
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
    /// Pull a string value from an rcp_cur_str/int reply. CAMERA_ID is a
    /// "CameraName" value that arrives as rcp_cur_str ({"str":"GA"}) but may
    /// also be an int enum — accept either, preferring the string form.
    static func extractString(_ msg: [String: Any]?) -> String? {
        guard let msg else { return nil }
        func pick(_ obj: Any?) -> String? {
            if let s = obj as? String {
                let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
            }
            if let i = obj as? Int { return String(i) }
            if let d = obj as? Double { return String(Int(d)) }
            if let dict = obj as? [String: Any] {
                for key in ["str", "val", "value", "cur", "display"] {
                    if let inner = dict[key], let found = pick(inner) { return found }
                }
            }
            return nil
        }
        for key in ["str", "cur", "value", "display", "val"] {
            if let inner = msg[key], let found = pick(inner) { return found }
        }
        return nil
    }

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

        // RCP2 bodies have emitted both a direct array and an array nested under
        // a `cur`/`data` object. Walk only list-shaped keys so unrelated fields
        // such as min/max/status do not become phantom choices.
        func list(_ obj: Any?) -> [Int] {
            if let arr = obj as? [Any] {
                let direct = arr.compactMap { val($0) }
                if !direct.isEmpty { return direct }
                for item in arr {
                    let nested = list(item)
                    if !nested.isEmpty { return nested }
                }
            }
            if let dict = obj as? [String: Any] {
                for key in ["list", "values", "entries", "items", "options", "data", "cur"] {
                    let nested = list(dict[key])
                    if !nested.isEmpty { return nested }
                }
            }
            return []
        }
        return list(msg)
    }

    /// Parse the camera-advertised quality factors while preserving any labels
    /// supplied in `rcp_cur_list`. The documented Q-factor label remains the
    /// fallback because it is the stable RCP2 wire meaning.
    static func extractLivestreamQualityOptions(_ msg: [String: Any]?) -> [LivestreamQualityOption] {
        guard let msg else { return [] }

        func integer(_ obj: Any?) -> Int? {
            if let i = obj as? Int { return i }
            if let d = obj as? Double { return Int(d) }
            if let s = obj as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            if let dict = obj as? [String: Any] {
                for key in ["val", "value", "num", "id"] {
                    if let found = integer(dict[key]) { return found }
                }
            }
            return nil
        }

        func text(_ obj: Any?) -> String? {
            if let s = obj as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let dict = obj as? [String: Any] {
                for key in ["label", "display", "name", "abbr", "str"] {
                    if let found = text(dict[key]) { return found }
                }
            }
            return nil
        }

        func optionArray(_ obj: Any?) -> [LivestreamQualityOption] {
            if let arr = obj as? [Any] {
                var found: [LivestreamQualityOption] = []
                for item in arr {
                    if let value = integer(item), (1...4).contains(value) {
                        let documented = livestreamQualityLabels[value] ?? "\(value)"
                        let cameraText = text(item)
                        let label = cameraText.flatMap {
                            $0.caseInsensitiveCompare(documented) == .orderedSame ? nil : $0
                        }.map { "\(documented) · \($0)" } ?? documented
                        found.append(.init(value: value, label: label))
                    }
                }
                if !found.isEmpty { return found }
                for item in arr {
                    let nested = optionArray(item)
                    if !nested.isEmpty { return nested }
                }
            }
            if let dict = obj as? [String: Any] {
                // Some JSON bridges expose parallel value/display arrays.
                for valueKey in ["values", "list_values", "nums"] {
                    guard let values = dict[valueKey] as? [Any] else { continue }
                    let ints = values.compactMap(integer).filter { (1...4).contains($0) }
                    guard !ints.isEmpty else { continue }
                    for labelKey in ["labels", "strings", "displays", "names", "abbrs"] {
                        guard let labels = dict[labelKey] as? [Any],
                              labels.count == ints.count else { continue }
                        return zip(ints, labels).map { value, rawLabel in
                            let documented = livestreamQualityLabels[value] ?? "\(value)"
                            guard let cameraText = text(rawLabel),
                                  cameraText.caseInsensitiveCompare(documented) != .orderedSame else {
                                return .init(value: value, label: documented)
                            }
                            return .init(value: value, label: "\(documented) · \(cameraText)")
                        }
                    }
                }
                for key in ["list", "values", "entries", "items", "options", "data", "cur"] {
                    let nested = optionArray(dict[key])
                    if !nested.isEmpty { return nested }
                }
            }
            return []
        }

        var seen = Set<Int>()
        return optionArray(msg)
            .filter { seen.insert($0.value).inserted }
            .sorted { $0.value < $1.value }
    }

    /// Decode an actual LIVESTREAM_QUALITY read-back. RED permits both
    /// `rcp_cur_int` and `rcp_cur_str`; string replies may carry the SDK enum
    /// token instead of its integer. Camera-provided public labels are accepted
    /// only when their value relationship was learned from that body's list.
    static func extractLivestreamQuality(
        _ msg: [String: Any]?,
        options: [LivestreamQualityOption] = []
    ) -> Int? {
        if let integer = extractInt(msg), (1...4).contains(integer) { return integer }

        func normalized(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        }

        let raw = extractDisplay(msg)
        guard !raw.isEmpty else { return nil }
        let token = normalized(raw)
        let documented: [String: Int] = [
            "Q25": 1, "Q_FACTOR_25": 1, "JPEG_QUALITY_Q_FACTOR_25": 1,
            "Q50": 2, "Q_FACTOR_50": 2, "JPEG_QUALITY_Q_FACTOR_50": 2,
            "Q75": 3, "Q_FACTOR_75": 3, "JPEG_QUALITY_Q_FACTOR_75": 3,
            "Q100": 4, "Q_FACTOR_100": 4, "JPEG_QUALITY_Q_FACTOR_100": 4,
        ]
        if let value = documented[token] { return value }
        for (suffix, value) in [
            ("Q_FACTOR_25", 1), ("Q_FACTOR_50", 2),
            ("Q_FACTOR_75", 3), ("Q_FACTOR_100", 4),
        ] where token.hasSuffix(suffix) {
            return value
        }

        // A decoded list label may be stored as "Q75 · High". Compare every
        // component, but never invent a Low/Medium/High mapping without that
        // camera-supplied relationship.
        for option in options {
            let components = option.label.split(separator: "·").map {
                normalized(String($0))
            }
            if components.contains(token) { return option.value }
        }
        return nil
    }

    /// True for a real HH:MM:SS(:|;FF) timecode — guards against placeholder junk.
    static func looksLikeTC(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^\d{1,2}:\d{2}:\d{2}(?:[:;]\d{2})?$"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }
}
