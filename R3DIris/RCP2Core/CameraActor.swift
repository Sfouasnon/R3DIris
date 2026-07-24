//  CameraActor.swift — R3DIris / RCP2Core
//  Session lifecycle + live state for ONE camera. One actor, one session, ever
//  (RCP2_FIELD_NOTES.md rule 2). Ported from REDConductorV3's CameraActor (the
//  proven implementation) with the run/stop engine removed and the Phase 0
//  bench surface added: aperture + livestream operations, all operator-triggered.
//
//    rule 4  — reconnect backoff 3s→12s, PARK after 6 consecutive failures
//    rule 7  — traffic watchdog: quiet >3s → one heartbeat; >15s → reconnect
//    rule 8  — init must fail if the endpoint accepts TCP but answers nothing
//    rule 9  — subscription-first; NO routine polling of any kind
//    rule 10 — one-off gets are unsubscribed afterwards (implicit-sub residue)
//    rule 11 — advertised params only; never blind rcp_gets. Aperture params
//              remain # UNVERIFIED (no e-iris body benched): they may ONLY be
//              touched through the bench methods below, one deliberate operator
//              action at a time, on a session the operator is prepared to lose.
//    rule 13 — request/response transactions are serialized
//    rule 14 — rcp_session/rcp_footer are serial-only; ignore on WS, never echo

import Foundation

actor CameraActor {
    // MARK: Tunables (all from field notes; change only with bench evidence)
    static let reconnectDelayBase: TimeInterval = 3.0
    static let reconnectDelayMax: TimeInterval = 12.0
    static let parkAfterFails = 6
    static let heartbeatAfterQuiet: TimeInterval = 3.0
    static let staleLinkAfterQuiet: TimeInterval = 15.0

    nonisolated let ip: String

    private let sourceIP: String?
    private let onStatus: @Sendable (CameraStatus) -> Void
    private let onLog: @Sendable (String) -> Void

    private var status = CameraStatus()
    private var session: RCP2Session?
    private var runTask: Task<Void, Never>?
    private var running = false
    private var fastReconnect = false
    private var connectFails = 0
    private var lastSeen: Date?
    private var lastTX: (date: Date, type: String, id: String)?
    private var advertised: Set<String> = []
    private var unsubscribed: Set<String> = []
    private var apertureSubscribed = false   // bench gate (rule 11) — survives reconnect

    init(ip: String, sourceIP: String?,
         onStatus: @escaping @Sendable (CameraStatus) -> Void,
         onLog: @escaping @Sendable (String) -> Void) {
        self.ip = ip
        self.sourceIP = sourceIP
        self.onStatus = onStatus
        self.onLog = onLog
    }

    // MARK: - Public lifecycle

    func start() {
        guard !running else { return }
        running = true
        status.link = .connecting
        status.lastError = ""
        publish()
        runTask = Task { await self.runForever() }
    }

    func stop() async {
        running = false
        if let session {
            await session.close(gracefulTimeout: 1)
        }
        status.link = .disconnected
        publish()
    }

    /// Revive a parked (or never-started) camera — operator Refresh (rule 4).
    func revive() {
        connectFails = 0
        if status.link == .parked || !running {
            running = false   // let a finished run loop restart cleanly
            runTask?.cancel()
            runTask = nil
            start()
        }
    }

    /// Tear the session down so the run loop reconnects and re-subscribes.
    /// fast=true only for operator-facing revives; the watchdog must use
    /// fast=false so repeated teardowns can't churn the camera's session pool.
    func forceReconnect(reason: String, fast: Bool) async {
        guard let session else { return }
        log("forcing reconnect: \(reason) (last tx: \(lastTXDescription()))")
        status.link = .connecting
        status.lastError = "reconnecting (\(reason))"
        fastReconnect = fast
        publish()
        await session.close(gracefulTimeout: fast ? 1 : 3)   // rule 3
    }

    func currentStatus() -> CameraStatus { status }

    // MARK: - Run loop

    private func runForever() async {
        while running {
            let session = RCP2Session(ip: ip, sourceIP: sourceIP)
            self.session = session
            var opened = false
            do {
                status.link = .connecting
                publish()
                try await session.open(timeout: 5)
                opened = true
                let consumer = Task { await self.consume(session) }
                try await initialize(session)
                status.link = .connected
                status.lastError = ""
                connectFails = 0
                lastSeen = Date()
                publish()
                log("connected (\(status.displayID.isEmpty ? ip : status.displayID), FW \(status.firmware))")
                let watchdog = Task { await self.watchdogLoop() }
                await consumer.value          // returns when the socket dies/closes
                watchdog.cancel()
            } catch {
                status.lastError = String(describing: error)
                if opened {
                    // TCP/WS accepted but RCP2 never answered init — close
                    // GRACEFULLY anyway so the camera-side slot is freed (rule 3/8).
                    await session.close(gracefulTimeout: 3)
                } else {
                    // Handshake never completed — no camera-side WS session
                    // exists yet, so a hard cancel is safe here (and required:
                    // open() may have timed out with the connection still trying).
                    session.abort()
                }
            }
            self.session = nil
            resetLiveReadings()
            failAllWaiters()

            guard running else { break }
            connectFails += 1
            if connectFails >= Self.parkAfterFails {
                // rule 4 — PARK. A powered-off body must never generate a storm.
                status.link = .parked
                status.lastError = "parked (unreachable) — revive with Refresh"
                publish()
                log("parked after \(connectFails) failed connects")
                connectFails = 0
                running = false
                break
            }
            status.link = .connecting
            publish()
            let delay = fastReconnect ? 0 : min(Self.reconnectDelayBase * Double(connectFails), Self.reconnectDelayMax)
            fastReconnect = false
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        if status.link != .parked {
            status.link = .disconnected
            publish()
        }
    }

    private func resetLiveReadings() {
        // A dropped camera must not keep reporting stale readings as good.
        status.link = running ? .connecting : .disconnected
        status.tcSeenAt = nil
        status.apertureSeenAt = nil
        status.livestreamQuality = nil
        status.livestreamQualityOptions = []
        publish()
    }

    // MARK: - Init sequence (field notes "Init sequence" section)

    private func initialize(_ session: RCP2Session) async throws {
        try await session.send([
            "type": "rcp_config",
            "strings_decoded": 1,
            "json_minified": 1,
            "include_cacheable_flags": 0,
            "encoding_type": "legacy",
            "client": ["name": RCP2.clientName, "version": RCP2.clientVersion],
        ])
        let types = await sendAndWait(["type": "rcp_get_types"],
                                      replyKeys: ["rcp_cur_types"], timeout: 5)
        let info = await sendAndWait(["type": "rcp_get", "id": "CAMERA_INFO"],
                                     replyKeys: ["rcp_cur_cam_info"], timeout: 5)
        applyCameraInfo(info)
        // Array identifier (e.g. "GC") = reel letter + clip letter from the
        // clip name ("G001_C001" → "GC"). CLIP_NAME_2 is the live param but is
        // get-only (no subscribe); CLIP_NAME is the deprecated fallback. Log the
        // raw value + derived id so a body sending an odd shape is diagnosable.
        for idParam in ["CLIP_NAME_2", "CLIP_NAME"] {
            let reply = await sendAndWait(["type": "rcp_get", "id": idParam],
                                          replyKeys: ["rcp_cur_str", "rcp_cur_int"], timeout: 3)
            if let raw = RCP2.extractString(reply), !raw.isEmpty {
                status.clipName = raw
                log("\(idParam) = \(raw) → id \(status.rcpIdentifier.isEmpty ? "(no 2-letter match)" : status.rcpIdentifier)")
                break
            } else {
                log("\(idParam) = (empty)")
            }
        }
        let params = await sendAndWait(["type": "rcp_get_parameters"],
                                       replyKeys: ["rcp_cur_parameters"], timeout: 5)
        if let list = params?["parameters"] as? [Any] {
            advertised = Set(list.map { RCP2.normParamID($0) }.filter { !$0.isEmpty })
        }
        log("advertised params: \(advertised.isEmpty ? "none (FW 2.2.4 behavior)" : String(advertised.count))")
        // rule 8 — TCP-open-but-mute must not count as a connected camera.
        guard types != nil || info != nil || params != nil else {
            throw RCP2Session.SessionError.connectFailed(
                "RCP2 endpoint did not answer init (get_types / CAMERA_INFO / get_parameters)")
        }
        // rule 9 — subscribe once; the camera pushes from here on.
        unsubscribed.removeAll()
        for pid in RCP2.subscribedParams {
            try await session.send(["type": "rcp_subscribe", "id": pid, "on_off": true])
        }
        // Bench gate: re-arm the aperture subscription across reconnects only if
        // the operator had it on (rule 11 — never automatic on first connect).
        if apertureSubscribed {
            try? await session.send(["type": "rcp_subscribe", "id": RCP2.apertureParam, "on_off": true])
        }
    }

    private func applyCameraInfo(_ info: [String: Any]?) {
        guard let info else { return }
        if let name = info["name"] as? String, !name.isEmpty { status.name = name }
        if let serial = info["serial_number"] as? String, !serial.isEmpty { status.serial = serial }
        if let ver = info["version"] as? [String: Any], let s = ver["str"] as? String, !s.isEmpty {
            status.firmware = s
        } else if let s = info["version"] as? String, !s.isEmpty {
            status.firmware = s
        }
    }

    // MARK: - Heartbeat (rule 7)

    /// One lightweight request to provoke traffic on a quiet link.
    /// RECORD_STATE is in the subscribe list, so it leaves no residue.
    private func heartbeat() async -> Bool {
        await sendAndWait(["type": "rcp_get", "id": "RECORD_STATE"],
                          replyKeys: ["param:RECORD_STATE"], timeout: 1.0) != nil
    }

    private func watchdogLoop() async {
        var lastHeartbeat = Date.distantPast
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            guard status.link == .connected, let last = lastSeen else { continue }
            let quiet = Date().timeIntervalSince(last)
            if quiet > Self.staleLinkAfterQuiet {
                // Patience is cheap; teardown is not. 15s tolerates the multi-
                // second camera-side busy spells seen live on 2026-07-07.
                await forceReconnect(reason: "stale link (\(Int(quiet))s silent)", fast: false)
                return
            }
            if quiet > Self.heartbeatAfterQuiet,
               Date().timeIntervalSince(lastHeartbeat) > Self.heartbeatAfterQuiet {
                lastHeartbeat = Date()
                _ = await heartbeat()
            }
        }
    }

    // MARK: - Bench surface (Phase 0 — every call is one operator action)
    //
    // Aperture params remain # UNVERIFIED on a body (rule 11); livestream and
    // monitor-transform params are bench-verified. benchGet returns the raw
    // reply so the UI logs exactly what came back; nil = timeout, which can mean
    // a WEDGED session (TCP up, pushes stopped — watch the TC tick; reconnect
    // clears it).

    /// Deliberate one-off get. rule 10: every rcp_get
    /// implicitly subscribes camera-side — cancel the residue once per session.
    func benchGet(_ pid: String, timeout: TimeInterval = 2.0) async -> [String: Any]? {
        let pid = RCP2.normParamID(pid)
        if !advertised.isEmpty && !advertised.contains(pid) && !RCP2.coreParams.contains(pid) {
            log("bench get \(pid): REFUSED — camera advertises a param list and \(pid) is not in it (rule 11)")
            return nil
        }
        log("bench get \(pid)")
        let resp = await sendAndWait(["type": "rcp_get", "id": pid],
                                     replyKeys: ["param:\(pid)"], timeout: timeout)
        if !RCP2.subscribedParams.contains(pid) && !unsubscribed.contains(pid)
            && !(pid == RCP2.apertureParam && apertureSubscribed) {
            unsubscribed.insert(pid)
            try? await session?.send(["type": "rcp_subscribe", "id": pid, "on_off": false])
        }
        return resp
    }

    /// Bench gate: subscribe APERTURE so cur/target pushes arrive during moves
    /// (the settle detector). Enable only while watching for a session wedge.
    func setApertureSubscription(_ on: Bool) async {
        apertureSubscribed = on
        unsubscribed.remove(RCP2.apertureParam)
        guard let session, status.link == .connected else { return }
        try? await session.send(["type": "rcp_subscribe", "id": RCP2.apertureParam, "on_off": on])
        log("APERTURE subscription \(on ? "ENABLED (watch for wedge)" : "disabled")")
    }

    /// `rcp_get_list APERTURE` — the mounted lens's valid stop values (×10).
    /// Fetch once per lens mount; gives real min/max range and granularity.
    func getApertureList(timeout: TimeInterval = 3.0) async -> [Int] {
        log("bench get_list APERTURE →")
        let resp = await sendAndWait(["type": "rcp_get_list", "id": RCP2.apertureParam],
                                     replyKeys: ["rcp_cur_list:\(RCP2.apertureParam)",
                                                 "param:\(RCP2.apertureParam)"], timeout: timeout)
        let list = RCP2.extractIntList(resp)
        if !list.isEmpty {
            status.apertureList = list
            publish()
        }
        return list
    }

    /// The SET: `{"type":"rcp_set","id":"APERTURE","value":56}` — stop ×10.
    /// Camera moves the iris toward target; watch pushed cur converge (settle).
    func setAperture(x10 value: Int) async -> Bool {
        guard let session else { return false }
        log("rcp_set APERTURE \(value) (\(RCP2.stopLabel(value)))")
        do {
            try await session.send(["type": "rcp_set", "id": RCP2.apertureParam, "value": value])
            return true
        } catch {
            status.lastError = String(describing: error)
            publish()
            return false
        }
    }

    /// The iris nudge: step ±n entries through the camera's own valid-stop list
    /// (`rcp_set_list_relative` — param-set v6.1+; KOMODO-X FW 2.2.4 advertises
    /// it per the docs — verify on the bench).
    func nudgeAperture(offset: Int) async -> Bool {
        guard let session else { return false }
        log("rcp_set_list_relative APERTURE offset \(offset > 0 ? "+" : "")\(offset)")
        do {
            try await session.send(["type": "rcp_set_list_relative", "id": RCP2.apertureParam, "offset": offset])
            return true
        } catch {
            status.lastError = String(describing: error)
            publish()
            return false
        }
    }

    /// LIVESTREAM_ENABLE 0/1 — the port-9090 multipart-JPEG stream. Plain HTTP,
    /// completely separate from this WS session; no session-slot cost expected.
    func setLivestream(enabled: Bool) async -> Bool {
        guard let session else { return false }
        log("rcp_set LIVESTREAM_ENABLE \(enabled ? 1 : 0)")
        do {
            try await session.send(["type": "rcp_set", "id": RCP2.livestreamEnableParam, "value": enabled ? 1 : 0])
            return true
        } catch {
            status.lastError = String(describing: error)
            publish()
            return false
        }
    }

    /// Ask the body which LIVESTREAM_QUALITY factors are valid in its current
    /// configuration. The current RCP2 definition is Q25/Q50/Q75/Q100 (1...4),
    /// but this list is the body's runtime truth and is retained in status for
    /// the bench manifest and operator UI.
    func getLivestreamQualityOptions(timeout: TimeInterval = 2.0) async -> [LivestreamQualityOption] {
        log("rcp_get_list LIVESTREAM_QUALITY")
        let reply = await sendAndWait(
            ["type": "rcp_get_list", "id": RCP2.livestreamQualityParam],
            replyKeys: ["rcp_cur_list:\(RCP2.livestreamQualityParam)",
                        "param:\(RCP2.livestreamQualityParam)",
                        "rcp_cur_list"],
            timeout: timeout)
        if let reply,
           let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            log("LIVESTREAM_QUALITY list raw \(raw)")
        }
        let options = RCP2.extractLivestreamQualityOptions(reply)
        status.livestreamQualityOptions = options
        publish()
        let description = options.isEmpty
            ? "no list reply"
            : options.map { "\($0.label)=\($0.value)" }.joined(separator: ", ")
        log("LIVESTREAM_QUALITY factors: \(description)")
        return options
    }

    /// Read the quality the camera is actually using. This is intentionally a
    /// one-off get, not a cached/requested value.
    func readLivestreamQuality(timeout: TimeInterval = 2.0) async -> Int? {
        unsubscribed.remove(RCP2.livestreamQualityParam)
        let reply = await benchGet(RCP2.livestreamQualityParam, timeout: timeout)
        let actual = RCP2.extractLivestreamQuality(
            reply,
            options: status.livestreamQualityOptions
        )
        status.livestreamQuality = actual
        publish()
        return actual
    }

    /// Clear a failed validation read so an older stream-rect payload cannot be
    /// mistaken for end-of-trial provenance.
    func clearLivestreamRectReadback() {
        status.rectPixels = ""
        publish()
    }

    /// LIVESTREAM_QUALITY 1–4 → Q25/Q50/Q75/Q100. Send the exact protocol
    /// value the operator selected, then return the independent actual read-back.
    /// Never substitute a different per-camera factor: the array gate compares
    /// actual values and must not hide a mixed-quality measurement behind local
    /// fallback choices.
    @discardableResult
    func setLivestreamQuality(_ q: Int) async -> LivestreamQualityVerification {
        guard let session, (1...4).contains(q) else {
            return LivestreamQualityVerification(requested: q, actual: nil, options: [])
        }

        let options = await getLivestreamQualityOptions()
        if !options.isEmpty, !options.contains(where: { $0.value == q }) {
            log("LIVESTREAM_QUALITY \(RCP2.livestreamQualityLabels[q] ?? "\(q)") is not in the camera's actual list — sending the exact requested value so read-back can prove acceptance or rejection")
        }

        log("rcp_set LIVESTREAM_QUALITY \(q) (\(RCP2.livestreamQualityLabels[q] ?? "?"))")
        do {
            try await session.send(["type": "rcp_set", "id": RCP2.livestreamQualityParam, "value": q])
        } catch {
            status.lastError = String(describing: error)
            publish()
            return LivestreamQualityVerification(requested: q, actual: nil, options: options)
        }

        // Firmware may apply the JPEG encoder setting asynchronously. Use a
        // bounded read-back sequence instead of trusting one arbitrary delay.
        var readBack: Int?
        for delayMS in [150, 350, 700] {
            try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
            readBack = await readLivestreamQuality()
            if readBack == q { break }
        }
        let confirmed = (readBack == q)
        let seen = readBack.map { RCP2.livestreamQualityLabels[$0] ?? "\($0)" } ?? "no reply"
        log("LIVESTREAM_QUALITY \(confirmed ? "CONFIRMED at \(RCP2.livestreamQualityLabels[q] ?? "\(q)")" : "NOT CONFIRMED — requested \(RCP2.livestreamQualityLabels[q] ?? "\(q)"), actual read-back \(seen)")")
        return LivestreamQualityVerification(requested: q, actual: readBack, options: options)
    }

    // MARK: Monitor viewing transform (rule 11)

    /// Read the monitor-output preset that feeds the active livestream mirror.
    /// This is intentionally operator-triggered (Prepare / Start Match), never
    /// part of connection initialization. Record-side image-pipeline params are
    /// never touched.
    func readActiveMonitorTransform(timeout: TimeInterval = 2.0) async -> MonitorTransformReading {
        let mirrorReply = await benchGet(RCP2.livestreamMirrorSourceParam, timeout: timeout)
        // This operation is a measurement preflight: never fall back to a
        // cached mirror source after a missing reply.
        let mirrorReadback = RCP2.extractInt(mirrorReply)
        status.mirrorSource = mirrorReadback
        guard let mirror = mirrorReadback, (1...3).contains(mirror) else {
            status.monitorTransformParam = ""
            status.monitorTransformValue = nil
            status.monitorTransformSeenAt = nil
            publish()
            log("monitor transform: UNKNOWN — no fresh, valid livestream mirror-source read-back")
            return MonitorTransformReading(mirrorSource: mirrorReadback)
        }
        let candidates = RCP2.monitorDisplayPresetCandidates(forMirrorSource: mirror)
        let pid = advertised.isEmpty
            ? candidates.first
            : candidates.first(where: { advertised.contains($0) })
        guard let pid else {
            status.monitorTransformParam = ""
            status.monitorTransformValue = nil
            status.monitorTransformSeenAt = nil
            publish()
            log("monitor transform: UNKNOWN — livestream mirror source \(mirror) has no output preset mapping")
            return MonitorTransformReading(mirrorSource: mirror)
        }

        // Set the expected active param before the reply lands so a mirror
        // source change can never leave a stale preset presented as current.
        status.monitorTransformParam = pid
        status.monitorTransformValue = nil
        status.monitorTransformSeenAt = nil
        publish()

        let reply = await benchGet(pid, timeout: timeout)
        let value = RCP2.extractInt(reply)
        if let value {
            status.monitorTransformValue = value
            status.monitorTransformSeenAt = Date()
            publish()
        }
        let label = value.flatMap { RCP2.displayPresetLabels[$0] } ?? "UNKNOWN"
        log("monitor transform: mirror \(RCP2.mirrorSourceLabels[mirror] ?? "source \(mirror)") → \(pid) = \(value.map(String.init) ?? "no reply") (\(label))")
        return MonitorTransformReading(mirrorSource: mirror,
                                       parameterID: pid,
                                       presetValue: value)
    }

    /// One deliberate rule-11 action: switch only the output currently feeding
    /// the livestream mirror to Log3G10, then read it back. Never changes the
    /// record-side RWG/Log3G10 metadata/image pipeline.
    func setActiveMonitorLog3G10() async -> Bool {
        let reading = await readActiveMonitorTransform()
        guard status.link == .connected, !reading.parameterID.isEmpty else {
            log("set Log3G10: REFUSED — active livestream mirror output is unknown")
            return false
        }
        return await setMonitorDisplayPreset(parameterID: reading.parameterID,
                                             value: RCP2.log3G10DisplayPresetValue,
                                             reason: "set Log3G10")
    }

    /// Read a monitor param's current value (cur, else target). Used to capture
    /// a specific output's Look before the operator-chosen Log3G10 swap.
    func monitorParamValue(_ pid: String) async -> Int? {
        unsubscribed.remove(pid)
        let msg = await benchGet(pid)
        let (cur, target) = RCP2.extractCurTarget(msg)
        return cur ?? target ?? RCP2.extractInt(msg)
    }

    /// Restore a saved Look on its exact param (unconditional — used by the
    /// explicit LCD/SDI swap, which knows precisely what it changed).
    func restoreColorSetting(_ saved: MonitorTransformReading) async -> Bool {
        guard !saved.parameterID.isEmpty, let v = saved.presetValue else { return true }
        return await setMonitorDisplayPreset(parameterID: saved.parameterID, value: v,
                                             reason: "restore Look")
    }

    /// Set one known monitor-output preset and verify its readback. This is
    /// shared by the explicit Log3G10 action and Manual Assist's reversible
    /// output transaction; it never touches record-side color/gamma settings.
    func setMonitorDisplayPreset(parameterID pid: String, value: Int,
                                 reason: String) async -> Bool {
        guard RCP2.monitorDisplayPresetParams.contains(pid) else {
            log("\(reason): REFUSED — \(pid) is not a monitor display-preset parameter")
            return false
        }
        guard let session, status.link == .connected else {
            log("\(reason): REFUSED — camera session is not connected")
            return false
        }
        let label = RCP2.displayPresetLabels[value] ?? "PRESET \(value)"
        log("rcp_set \(pid) \(value) (\(label); output-side)")
        do {
            try await session.send([
                "type": "rcp_set", "id": pid,
                "value": value,
            ])
        } catch {
            status.lastError = String(describing: error)
            publish()
            return false
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        // A SET may itself leave subscription residue. Re-arm benchGet's
        // one-off unsubscribe discipline for the verification read (rule 10).
        unsubscribed.remove(pid)
        let verify = await benchGet(pid)
        // DISPLAY_PRESET_* are "Value (with target)" params (KOMODO-X PDF): a SET
        // moves TARGET immediately while CUR transitions over a few frames.
        // Confirm against the target (the commanded value) — reading cur alone
        // races the transition and false-fails (bench 2026-07-20).
        let (cur, target) = RCP2.extractCurTarget(verify)
        let readVal = target ?? cur ?? RCP2.extractInt(verify)
        let confirmed = (readVal == value)
        if confirmed {
            status.monitorTransformParam = pid
            status.monitorTransformValue = value
            status.monitorTransformSeenAt = Date()
            publish()
        }
        log("\(reason): \(confirmed ? "CONFIRMED" : "NOT CONFIRMED — camera reports \(readVal.map(String.init) ?? "no value")") on \(pid) = \(value) (\(label))")
        return confirmed
    }

    /// Restore a display preset captured before Manual Assist. Restoration is
    /// deliberately conservative: if the mirrored output changed, or an
    /// operator selected a third preset during the session, do not overwrite
    /// that newer choice.
    func restoreMonitorTransform(_ saved: MonitorTransformReading) async -> Bool {
        guard let savedValue = saved.presetValue, !saved.parameterID.isEmpty else {
            log("restore monitor transform: REFUSED — saved preset is incomplete")
            return false
        }
        let current = await readActiveMonitorTransform()
        guard current.parameterID == saved.parameterID else {
            log("restore monitor transform: REFUSED — livestream mirror output changed (saved \(saved.parameterID), active \(current.parameterID.isEmpty ? "unknown" : current.parameterID))")
            return false
        }

        // DISPLAY_PRESET_* is value-with-target. A delayed restore must inspect
        // TARGET as well as CUR: immediately after an interrupted Log3G10 SET,
        // CUR can still equal the saved preset while TARGET is already Log3G10.
        // Treating CUR alone as "already restored" could strand the camera after
        // the transition completes.
        unsubscribed.remove(saved.parameterID)
        let raw = await benchGet(saved.parameterID)
        let (cur, target) = RCP2.extractCurTarget(raw)
        let commanded = target ?? cur ?? RCP2.extractInt(raw)
        if target == savedValue || (target == nil && commanded == savedValue) {
            log("restore monitor transform: already at saved preset \(savedValue) on \(saved.parameterID)")
            return true
        }
        guard commanded == RCP2.log3G10DisplayPresetValue else {
            let detail = commanded.map(String.init) ?? "no value"
            log("restore monitor transform: REFUSED — active target changed during Manual Assist (\(detail))")
            return false
        }
        return await setMonitorDisplayPreset(parameterID: saved.parameterID,
                                             value: savedValue,
                                             reason: "restore monitor transform")
    }

    // MARK: - Receive path

    private func consume(_ session: RCP2Session) async {
        for await data in session.incoming {
            lastSeen = Date()
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let msg = obj as? [String: Any] else { continue }
            await dispatch(msg)
        }
    }

    private func dispatch(_ msg: [String: Any]) async {
        let type = msg["type"] as? String ?? ""
        let pid = RCP2.normParamID(msg["id"])

        if type == "rcp_session" || type == "rcp_footer" {
            // rule 14 — DIRECT-SERIAL-ONLY objects; ignore on WS, NEVER echo.
            return
        }

        let before = status
        switch pid {
        case "RECORD_STATE":
            if let v = RCP2.extractInt(msg) { status.recordState = v }
        case "TIMECODE":
            // Match on id + content, never on wrapper type (varies by TC source).
            let tc = RCP2.extractDisplay(msg)
            if RCP2.looksLikeTC(tc) {
                status.currentTC = tc
                status.tcSeenAt = Date()
            }
        case "CLIP_NAME_2", "CLIP_NAME":
            // The array identifier (GA/GB) is derived from the clip name, not
            // CAMERA_ID — matching REDConductorV3. CLIP_NAME_2 is the live param
            // (CLIP_NAME is deprecated). Log the first value so a body that
            // sends an unexpected shape is diagnosable.
            let s = RCP2.extractDisplay(msg)
            if !s.isEmpty, s != status.clipName {
                status.clipName = s
                log("clip name = \(s) → id \(status.rcpIdentifier.isEmpty ? "(no 2-letter match)" : status.rcpIdentifier)")
            }
        case RCP2.apertureParam:
            // Value-with-target: cur = where the iris is, target = where it's
            // been told to go. cur == target ⇒ settled (the loop's debounce).
            let (cur, target) = RCP2.extractCurTarget(msg)
            if cur != nil || target != nil {
                if let cur { status.apertureCur = cur }
                if let target { status.apertureTarget = target }
                status.apertureSeenAt = Date()
            } else if let v = RCP2.extractInt(msg) {
                status.apertureCur = v
                status.apertureSeenAt = Date()
            }
        case RCP2.apertureControlParam:
            if let v = RCP2.extractInt(msg) { status.apertureControl = v }
        case RCP2.apertureListModeParam:
            if let v = RCP2.extractInt(msg) { status.apertureListMode = v }
        case RCP2.aeModeParam:
            if let v = RCP2.extractInt(msg) { status.aeMode = v }
        case RCP2.aeLockApertureParam:
            if let v = RCP2.extractInt(msg) { status.aeLockAperture = v }
        case RCP2.livestreamEnableParam:
            if let v = RCP2.extractInt(msg) { status.livestreamEnabled = v }
        case RCP2.livestreamQualityParam:
            if type == "rcp_cur_list" {
                status.livestreamQualityOptions = RCP2.extractLivestreamQualityOptions(msg)
            } else if let v = RCP2.extractLivestreamQuality(
                msg,
                options: status.livestreamQualityOptions
            ) {
                status.livestreamQuality = v
            }
        case RCP2.livestreamMirrorSourceParam:
            if let v = RCP2.extractInt(msg) {
                status.mirrorSource = v
                let compatible = RCP2.monitorDisplayPresetCandidates(forMirrorSource: v)
                if !compatible.contains(status.monitorTransformParam) {
                    status.monitorTransformParam = compatible.first ?? ""
                    status.monitorTransformValue = nil
                    status.monitorTransformSeenAt = nil
                }
            }
        case RCP2.livestreamRectPixelsParam:
            // Keep the raw payload verbatim — the sensor→stream rect shape is
            // undocumented; the bench log is where we learn it.
            if let data = try? JSONSerialization.data(
                withJSONObject: msg,
                options: [.sortedKeys]
            ),
               let s = String(data: data, encoding: .utf8) {
                status.rectPixels = s
            }
        case let pid where RCP2.monitorDisplayPresetParams.contains(pid):
            status.monitorTransformParam = pid
            if let v = RCP2.extractInt(msg) {
                status.monitorTransformValue = v
                status.monitorTransformSeenAt = Date()
            }
        default:
            break
        }
        if status != before { publish() }

        // Deliver to a pending request/response waiter.
        var keys = [type]
        if !pid.isEmpty {
            keys.append("\(type):\(pid)")
            keys.append("param:\(pid)")
        }
        deliver(msg, toFirstOf: keys)
    }

    // MARK: - Request/response plumbing (rule 13 — strictly serialized)

    private final class Waiter {
        let token = UUID()
        var resumed = false
        let continuation: CheckedContinuation<[String: Any]?, Never>
        init(_ c: CheckedContinuation<[String: Any]?, Never>) { continuation = c }
    }

    private var waiters: [String: Waiter] = [:]
    private var ioBusy = false
    private var ioQueue: [CheckedContinuation<Void, Never>] = []

    private func acquireIO() async {
        if !ioBusy { ioBusy = true; return }
        await withCheckedContinuation { ioQueue.append($0) }
    }

    private func releaseIO() {
        if ioQueue.isEmpty { ioBusy = false } else { ioQueue.removeFirst().resume() }
    }

    private func sendAndWait(_ object: [String: Any], replyKeys: [String],
                             timeout: TimeInterval) async -> [String: Any]? {
        guard let session else { return nil }
        await acquireIO()
        defer { releaseIO() }
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            let waiter = Waiter(cont)
            for key in replyKeys { waiters[key] = waiter }
            lastTX = (Date(), object["type"] as? String ?? "?", object["id"] as? String ?? "")
            Task { [weak self] in
                do {
                    try await session.send(object)
                } catch {
                    await self?.settle(token: waiter.token, with: nil)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.settle(token: waiter.token, with: nil)
            }
        }
    }

    private func deliver(_ msg: [String: Any], toFirstOf keys: [String]) {
        for key in keys {
            if let waiter = waiters[key] {
                settle(token: waiter.token, with: msg)
                return
            }
        }
    }

    private func settle(token: UUID, with msg: [String: Any]?) {
        var target: Waiter?
        for (key, waiter) in waiters where waiter.token == token {
            target = waiter
            waiters.removeValue(forKey: key)
        }
        if let target, !target.resumed {
            target.resumed = true
            target.continuation.resume(returning: msg)
        }
    }

    private func failAllWaiters() {
        let all = Array(waiters.values)
        waiters.removeAll()
        for waiter in all where !waiter.resumed {
            waiter.resumed = true
            waiter.continuation.resume(returning: nil)
        }
    }

    // MARK: - Misc

    private func lastTXDescription() -> String {
        guard let lastTX else { return "none" }
        let ago = String(format: "%.1f", Date().timeIntervalSince(lastTX.date))
        return "\(lastTX.type) \(lastTX.id) \(ago)s ago"
    }

    private func publish() {
        onStatus(status)
    }

    private func log(_ line: String) {
        onLog(line)
    }
}
