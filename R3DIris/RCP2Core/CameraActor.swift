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
//    rule 11 — advertised params only; never blind rcp_gets. Aperture/livestream
//              params are # UNVERIFIED: they may ONLY be touched through the
//              bench methods below, one deliberate operator action at a time,
//              on a session the operator is prepared to lose.
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
                log("connected (\(status.name.isEmpty ? ip : status.name), FW \(status.firmware))")
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
    // All aperture/livestream params are # UNVERIFIED on a body (rule 11).
    // benchGet returns the raw reply so the UI logs exactly what came back;
    // nil = timeout, which after an unverified get may mean a WEDGED session
    // (TCP up, pushes stopped — watch the TC tick; reconnect clears it).

    /// Deliberate one-off get of an UNVERIFIED param. rule 10: every rcp_get
    /// implicitly subscribes camera-side — cancel the residue once per session.
    func benchGet(_ pid: String, timeout: TimeInterval = 2.0) async -> [String: Any]? {
        let pid = RCP2.normParamID(pid)
        if !advertised.isEmpty && !advertised.contains(pid) && !RCP2.coreParams.contains(pid) {
            log("bench get \(pid): REFUSED — camera advertises a param list and \(pid) is not in it (rule 11)")
            return nil
        }
        log("bench get \(pid) → (unverified param — watch for wedge: TC must keep ticking)")
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

    /// LIVESTREAM_QUALITY 1–4 → Q25/Q50/Q75/Q100. Measure at Q100 — JPEG
    /// compression perturbs patch statistics at low Q (LIVESTREAM_NOTES).
    func setLivestreamQuality(_ q: Int) async -> Bool {
        guard let session else { return false }
        log("rcp_set LIVESTREAM_QUALITY \(q) (\(RCP2.livestreamQualityLabels[q] ?? "?"))")
        do {
            try await session.send(["type": "rcp_set", "id": RCP2.livestreamQualityParam, "value": q])
            return true
        } catch {
            status.lastError = String(describing: error)
            publish()
            return false
        }
    }

    // MARK: Monitor viewing transform (rule 11; # UNVERIFIED)

    /// Read the monitor-output preset that feeds the active livestream mirror.
    /// This is intentionally operator-triggered (Prepare / Start Match), never
    /// part of connection initialization. Record-side image-pipeline params are
    /// never touched.
    func readActiveMonitorTransform(timeout: TimeInterval = 2.0) async -> MonitorTransformReading {
        let mirrorReply = await benchGet(RCP2.livestreamMirrorSourceParam, timeout: timeout)
        let mirror = RCP2.extractInt(mirrorReply) ?? status.mirrorSource
        let candidates = RCP2.monitorDisplayPresetCandidates(forMirrorSource: mirror)
        let pid = advertised.isEmpty
            ? candidates.first
            : candidates.first(where: { advertised.contains($0) })
        guard let pid else {
            status.monitorTransformParam = ""
            status.monitorTransformValue = nil
            status.monitorTransformSeenAt = nil
            publish()
            log("monitor transform: UNKNOWN — livestream mirror source \(mirror.map(String.init) ?? "unavailable") has no output preset mapping")
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
        log("monitor transform: mirror \(RCP2.mirrorSourceLabels[mirror ?? -1] ?? "source \(mirror ?? -1)") → \(pid) = \(value.map(String.init) ?? "no reply") (\(label))")
        return MonitorTransformReading(mirrorSource: mirror,
                                       parameterID: pid,
                                       presetValue: value)
    }

    /// One deliberate rule-11 action: switch only the output currently feeding
    /// the livestream mirror to Log3G10, then read it back. Never changes the
    /// record-side RWG/Log3G10 metadata/image pipeline.
    func setActiveMonitorLog3G10() async -> Bool {
        let reading = await readActiveMonitorTransform()
        guard let session, status.link == .connected,
              !reading.parameterID.isEmpty else {
            log("set Log3G10: REFUSED — active livestream mirror output is unknown")
            return false
        }
        let pid = reading.parameterID
        log("rcp_set \(pid) \(RCP2.log3G10DisplayPresetValue) (LOG3G10; output-side, # UNVERIFIED)")
        do {
            try await session.send([
                "type": "rcp_set", "id": pid,
                "value": RCP2.log3G10DisplayPresetValue,
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
        let confirmed = RCP2.extractInt(verify) == RCP2.log3G10DisplayPresetValue
        if confirmed {
            status.monitorTransformParam = pid
            status.monitorTransformValue = RCP2.log3G10DisplayPresetValue
            status.monitorTransformSeenAt = Date()
            publish()
        }
        log("set Log3G10: \(confirmed ? "CONFIRMED" : "NOT CONFIRMED") on \(pid)")
        return confirmed
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
            if let v = RCP2.extractInt(msg) { status.livestreamQuality = v }
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
            if let data = try? JSONSerialization.data(withJSONObject: msg),
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
