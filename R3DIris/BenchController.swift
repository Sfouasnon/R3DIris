//  BenchController.swift — R3DIris
//  @MainActor bridge between the UI and the one CameraActor (Phase 0 is a
//  single-body bench tool). Owns the bench log — the log IS the deliverable:
//  every raw reply gets written to it, and findings feed RCP2_APERTURE_NOTES.md
//  and RCP2_LIVESTREAM_NOTES.md.

import Foundation
import SwiftUI
import AppKit

@MainActor
final class BenchController: ObservableObject {
    @Published var ip: String = ""
    @Published var sourceIP: String = ""     // field notes rule 16 (link-local NICs)
    @Published private(set) var status = CameraStatus()
    @Published private(set) var logLines: [BenchLogLine] = []
    @Published var apertureSubscribed = false

    let stream = MJPEGStreamReader()

    private var camera: CameraActor?

    init() {
        stream.onLog = { [weak self] line in self?.log(line) }
    }

    // MARK: - Session lifecycle

    func connect() {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        disconnect()
        log("connecting to \(ip) (WS :\(RCP2.wsPort))…")
        let src = sourceIP.trimmingCharacters(in: .whitespaces)
        let cam = CameraActor(
            ip: ip,
            sourceIP: src.isEmpty ? nil : src,
            onStatus: { [weak self] s in
                Task { @MainActor in self?.status = s }
            },
            onLog: { [weak self] line in
                Task { @MainActor in self?.log(line) }
            })
        camera = cam
        Task { await cam.start() }
    }

    func disconnect() {
        stream.stop()
        if let cam = camera {
            camera = nil
            Task { await cam.stop() }   // graceful close — frees the session slot (rule 3)
            log("disconnected")
        }
        status = CameraStatus()
        apertureSubscribed = false
    }

    func refresh() {
        guard let cam = camera else { connect(); return }
        Task { await cam.revive() }
    }

    // MARK: - Bench actions: aperture (RCP2_APERTURE_NOTES.md checklist)

    /// Step 1/2 — capability gate + first APERTURE read on a sacrificial session.
    func checkApertureControl() {
        benchGet(RCP2.apertureControlParam) { [weak self] msg in
            guard let self else { return }
            if let v = RCP2.extractInt(msg) {
                self.log("→ APERTURE_CONTROL = \(v) (\(v == 1 ? "SUPPORTED — e-iris lens" : "NOT SUPPORTED — exposureAdjust-only fallback"))")
            }
        }
    }

    func getAperture() {
        benchGet(RCP2.apertureParam) { [weak self] msg in
            guard let self else { return }
            let (cur, target) = RCP2.extractCurTarget(msg)
            self.log("→ APERTURE cur \(RCP2.stopLabel(cur)) target \(RCP2.stopLabel(target))")
        }
    }

    func getApertureListMode() {
        benchGet(RCP2.apertureListModeParam) { [weak self] msg in
            guard let self else { return }
            if let v = RCP2.extractInt(msg) {
                self.log("→ APERTURE_LIST_MODE = \(v) (\(v == 0 ? "1/4-stop" : "1/3-stop") increments)")
            }
        }
    }

    /// Step 6 gate — if AE owns the iris the camera will fight the loop.
    func checkAE() {
        benchGet(RCP2.aeModeParam) { [weak self] msg in
            guard let self else { return }
            if let v = RCP2.extractInt(msg) {
                self.log("→ AE_MODE = \(v)\(v == 0 ? " (OFF — clean to dial)" : " (ON — AE may own the iris; check AE_LOCK_APERTURE)")")
            }
        }
        benchGet(RCP2.aeLockApertureParam) { [weak self] msg in
            guard let self else { return }
            if let v = RCP2.extractInt(msg) {
                self.log("→ AE_LOCK_APERTURE = \(v)")
            }
        }
    }

    /// Step 3 — valid stop list for the mounted lens.
    func getApertureList() {
        guard let cam = camera else { return }
        Task {
            let list = await cam.getApertureList()
            if list.isEmpty {
                log("→ APERTURE list: (no reply / empty — timeout may mean a wedge; watch TC)")
            } else {
                log("→ APERTURE list (\(list.count)): \(list.map { RCP2.stopLabel($0) }.joined(separator: " "))")
            }
        }
    }

    func toggleApertureSubscription() {
        guard let cam = camera else { return }
        apertureSubscribed.toggle()
        let on = apertureSubscribed
        Task { await cam.setApertureSubscription(on) }
    }

    /// Step 4 — absolute set; watch pushed cur converge to target for settle time.
    func setAperture(stopX10: Int) {
        guard let cam = camera else { return }
        let sentAt = Date()
        Task {
            _ = await cam.setAperture(x10: stopX10)
            // Settle measurement: poll our own pushed status (no camera traffic).
            for _ in 0..<100 {   // up to 10 s
                try? await Task.sleep(nanoseconds: 100_000_000)
                let s = await cam.currentStatus()
                if let cur = s.apertureCur, cur == stopX10 {
                    log("→ settled at \(RCP2.stopLabel(cur)) in \(String(format: "%.1f", Date().timeIntervalSince(sentAt)))s")
                    return
                }
            }
            let s = await cam.currentStatus()
            log("→ NOT settled after 10s (cur \(RCP2.stopLabel(s.apertureCur)) target \(RCP2.stopLabel(s.apertureTarget))) — subscribe APERTURE to see pushes, or the set was rejected (out of range? manual lens? AE?)")
        }
    }

    /// Step 5 — single list-step nudge.
    func nudgeAperture(_ offset: Int) {
        guard let cam = camera else { return }
        Task { _ = await cam.nudgeAperture(offset: offset) }
    }

    // MARK: - Bench actions: livestream (RCP2_LIVESTREAM_NOTES.md checklist)

    /// Step 1 — enable over WS, then GET :9090.
    func enableLivestreamAndView() {
        guard let cam = camera else { return }
        let ip = ip.trimmingCharacters(in: .whitespaces)
        Task {
            _ = await cam.setLivestream(enabled: true)
            try? await Task.sleep(nanoseconds: 700_000_000)   // give FW a beat to open :9090
            stream.start(ip: ip)
        }
    }

    func stopLivestream() {
        stream.stop()
        guard let cam = camera else { return }
        Task { _ = await cam.setLivestream(enabled: false) }
    }

    /// Step 4 — quality. Measure at 4 (Q100): low-Q JPEG perturbs patch stats.
    func setQuality(_ q: Int) {
        guard let cam = camera else { return }
        Task { _ = await cam.setLivestreamQuality(q) }
    }

    /// Step 5 — mirror source + sensor→stream rect (raw payload to the log).
    func readMirrorAndRect() {
        benchGet(RCP2.livestreamMirrorSourceParam) { [weak self] msg in
            guard let self else { return }
            if let v = RCP2.extractInt(msg) {
                self.log("→ LIVESTREAM_MIRROR_SOURCE = \(v) (\(RCP2.mirrorSourceLabels[v] ?? "?")) — all bodies must mirror identical monitor configs")
            }
        }
        benchGet(RCP2.livestreamRectPixelsParam) { _ in
            // raw payload already logged by benchGet; parsed rect lands in status
        }
    }

    // MARK: - Log

    func log(_ text: String) {
        logLines.append(BenchLogLine(text: text))
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
    }

    func logText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return logLines.map { "\(fmt.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }

    func saveLog() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "r3diris_bench_\(stamp).log"
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            try? self.logText().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Private

    /// Run one deliberate bench get, log the raw reply verbatim, then hand the
    /// parsed message to the caller. nil reply = timeout — on an unverified
    /// param that can mean a WEDGED session (rule 11): watch whether TC keeps
    /// ticking; reconnect clears it.
    private func benchGet(_ pid: String, _ handle: @escaping @MainActor ([String: Any]?) -> Void) {
        guard let cam = camera else { return }
        Task {
            let msg = await cam.benchGet(pid)
            if let msg,
               let data = try? JSONSerialization.data(withJSONObject: msg),
               let raw = String(data: data, encoding: .utf8) {
                log("← \(raw)")
            } else if msg == nil {
                log("← \(pid): NO REPLY (timeout) — if TC stops ticking the session is wedged; use Refresh")
            }
            handle(msg)
        }
    }
}
