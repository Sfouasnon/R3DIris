//  SoakRecorder.swift — R3DIris / Array
//  Live Sphere Soak capture and online QA metrics.
//
//  One row is written for every CameraNode analysis tick. The CSV is streamed
//  directly to disk; only the most recent 300 rows per camera remain in memory
//  for the live panel. Full-run summaries use constant-memory accumulators.

import Foundation

enum SoakDurationOption: String, CaseIterable, Identifiable {
    case thirtyMinutes = "30 min"
    case twoHours = "2 h"
    case eightHours = "8 h"
    case unbounded = "Unbounded"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .thirtyMinutes: return 30 * 60
        case .twoHours: return 2 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        case .unbounded: return nil
        }
    }
}

struct SoakAnalysisRow: Sendable {
    let timestamp: Date
    let cameraIP: String
    let tickSequence: UInt64
    let streamFPS: Double
    let analysisMS: Double
    let phase: SphereState.Phase
    let failureReason: String
    let cxNorm: Double?
    let cyNorm: Double?
    let radiusNorm: Double?
    let centerXPixel: Double?
    let centerYPixel: Double?
    let radiusPixel: Double?
    let heroIRE: Double?
    let chromaDistance: Double?
    let shadowRatio: Double?
    let interiorStd: Double?
    let ireSpread: Double?
    let hardFailed: Bool
}

struct SoakCameraMetric: Identifiable, Sendable, Equatable {
    var id: String { cameraIP }
    let cameraIP: String
    let ticks: Int
    let detectionPercent: Double
    let hardFailPercent: Double
    let lockUptimePercent: Double
    let centerJitterPixel: Double
    let centerMaxExcursionPixel: Double
    let radiusJitterPixel: Double
    let ireStd: Double
    let ireP5: Double?
    let ireP95: Double?
    let relockCount: Int
    let relockP50: Double?
    let relockP95: Double?
    let gateFailures: [String: Int]
}

struct SoakLiveSnapshot: Sendable, Equatable {
    var elapsed: TimeInterval = 0
    var totalTicks = 0
    var lockedTicks = 0
    var hardFailedTicks = 0
    var worstCenterJitterPixel: Double = 0
    var worstIREStd: Double = 0
    var pairwiseIRESpread: Double? = nil
    var pairwiseDisplayStops: Double? = nil
    var cameras: [SoakCameraMetric] = []
}

struct SoakSummary: Sendable {
    let csvURL: URL
    let summaryURL: URL
    let lines: [String]
}

@MainActor
final class SoakRecorder: ObservableObject {
    static let recentRowLimit = 300

    @Published private(set) var isRecording = false
    @Published private(set) var snapshot = SoakLiveSnapshot()
    @Published private(set) var lastError = ""

    var onDurationReached: (() -> Void)?
    var onLog: ((String) -> Void)?

    private var csvURL: URL?
    private var fileHandle: FileHandle?
    private var startedAt: Date?
    private var duration: SoakDurationOption = .unbounded
    private var tickSequences: [String: UInt64] = [:]
    private var recentRows: [String: [SoakAnalysisRow]] = [:]
    private var accumulators: [String: CameraAccumulator] = [:]
    private var latestIRE: [String: Double] = [:]
    private var rowsSinceSync = 0
    private var lastSnapshotAt = Date.distantPast
    private var durationCallbackSent = false
    private var matchQA = MatchQAAccumulator()

    func start(csvURL: URL, duration: SoakDurationOption) throws {
        guard !isRecording else { return }
        guard FileManager.default.createFile(atPath: csvURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: csvURL)
        self.csvURL = csvURL
        self.fileHandle = handle
        self.startedAt = Date()
        self.duration = duration
        tickSequences.removeAll(keepingCapacity: true)
        recentRows.removeAll(keepingCapacity: true)
        accumulators.removeAll(keepingCapacity: true)
        latestIRE.removeAll(keepingCapacity: true)
        matchQA = MatchQAAccumulator()
        rowsSinceSync = 0
        durationCallbackSent = false
        lastSnapshotAt = .distantPast
        lastError = ""
        snapshot = SoakLiveSnapshot()

        try writeLine(Self.csvHeader)
        isRecording = true
        onLog?("sphere soak: recording to \(csvURL.path) (\(duration.rawValue))")
    }

    func record(cameraIP: String,
                streamFPS: Double,
                analysisMS: Double,
                detection: SphereDetection?,
                state: SphereState) {
        guard isRecording, let startedAt else { return }

        let sequence = (tickSequences[cameraIP] ?? 0) + 1
        tickSequences[cameraIP] = sequence

        let gateValues = Dictionary(uniqueKeysWithValues:
            (detection?.gates ?? []).map { ($0.gate, $0.value) })
        let hasROI = state.hasROI
        let bufferWidth = detection.map { Double($0.bufferWidth) }
        let bufferHeight = detection.map { Double($0.bufferHeight) }
        let hardFailed = detection == nil || detection?.status == .failed
        let failedGate = detection?.gates.first(where: { !$0.passed })?.gate
        let failure = failedGate ?? detection?.failureReason ?? "analysis unavailable"

        let row = SoakAnalysisRow(
            timestamp: Date(), cameraIP: cameraIP, tickSequence: sequence,
            streamFPS: streamFPS, analysisMS: analysisMS,
            phase: state.phase,
            failureReason: failure,
            cxNorm: hasROI ? state.cx : nil,
            cyNorm: hasROI ? state.cy : nil,
            radiusNorm: hasROI ? state.r : nil,
            centerXPixel: hasROI ? bufferWidth.map { state.cx * $0 } : nil,
            centerYPixel: hasROI ? bufferHeight.map { state.cy * $0 } : nil,
            radiusPixel: hasROI ? bufferWidth.map { state.r * $0 } : nil,
            heroIRE: state.heroIRE,
            chromaDistance: gateValues["gray_material"],
            shadowRatio: gateValues["shadow_specular"] ?? gateValues["shadow_specular_pass2"],
            interiorStd: gateValues["interior_stddev"],
            ireSpread: gateValues["ire_spread"],
            hardFailed: hardFailed)

        do {
            try writeLine(csvLine(for: row))
        } catch {
            failRecording("CSV write failed: \(error.localizedDescription)")
            return
        }

        var recent = recentRows[cameraIP] ?? []
        recent.append(row)
        if recent.count > Self.recentRowLimit {
            recent.removeFirst(recent.count - Self.recentRowLimit)
        }
        recentRows[cameraIP] = recent

        var accumulator = accumulators[cameraIP] ?? CameraAccumulator()
        accumulator.add(row)
        accumulators[cameraIP] = accumulator

        if state.measurable, let ire = state.heroIRE {
            latestIRE[cameraIP] = ire
        } else {
            latestIRE.removeValue(forKey: cameraIP)
        }

        let now = Date()
        if now.timeIntervalSince(lastSnapshotAt) >= 0.5 {
            publishSnapshot(now: now)
        }
        if !durationCallbackSent, let limit = duration.seconds,
           now.timeIntervalSince(startedAt) >= limit {
            durationCallbackSent = true
            Task { @MainActor [weak self] in self?.onDurationReached?() }
        }
    }

    /// Structured loop QA rows share the CSV so exposure corrections can be
    /// correlated with the exact analysis ticks that drove them.
    func recordMatchEvent(_ event: String,
                          cameraIP: String = "",
                          round: Int? = nil,
                          nudges: Int? = nil,
                          directionFlips: Int? = nil,
                          finalSpreadIRE: Double? = nil,
                          finalSpreadStops: Double? = nil,
                          detail: String = "") {
        guard isRecording else { return }
        matchQA.add(event: event, cameraIP: cameraIP, round: round,
                    nudges: nudges, directionFlips: directionFlips,
                    finalSpreadIRE: finalSpreadIRE,
                    finalSpreadStops: finalSpreadStops)
        let fields = [
            "event", Self.isoFormatter.string(from: Date()), Self.csvEscape(cameraIP), "",
            "", "", "", "", "", "", "", "", "", "", "", "", "",
            round.map(String.init) ?? "", nudges.map(String.init) ?? "",
            directionFlips.map(String.init) ?? "",
            Self.number(finalSpreadIRE), Self.number(finalSpreadStops),
            Self.csvEscape(event), Self.csvEscape(detail),
        ]
        do {
            try writeLine(fields.joined(separator: ","))
        } catch {
            failRecording("event CSV write failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func stop(reason: String) -> SoakSummary? {
        guard isRecording, let csvURL, let startedAt else { return nil }
        publishSnapshot(now: Date())
        isRecording = false
        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
        } catch {
            lastError = "CSV close failed: \(error.localizedDescription)"
        }
        fileHandle = nil

        let summaryURL = csvURL.deletingLastPathComponent().appendingPathComponent(
            csvURL.deletingPathExtension().lastPathComponent + "_summary.txt")
        let lines = summaryLines(reason: reason, startedAt: startedAt, endedAt: Date(),
                                 csvURL: csvURL)
        do {
            try lines.joined(separator: "\n").appending("\n")
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = "summary write failed: \(error.localizedDescription)"
        }

        self.csvURL = nil
        self.startedAt = nil
        onLog?("sphere soak: stopped (\(reason)); summary \(summaryURL.path)")
        return SoakSummary(csvURL: csvURL, summaryURL: summaryURL, lines: lines)
    }

    private func failRecording(_ message: String) {
        lastError = message
        isRecording = false
        try? fileHandle?.close()
        fileHandle = nil
        onLog?("sphere soak: \(message)")
    }

    private func publishSnapshot(now: Date) {
        let metrics = accumulators.keys.sorted().compactMap { ip -> SoakCameraMetric? in
            guard let accumulator = accumulators[ip] else { return nil }
            return accumulator.metric(cameraIP: ip)
        }
        let ires = latestIRE.values.sorted()
        let spreadIRE = ires.count >= 2 ? (ires.last! - ires.first!) : nil
        let spreadStops: Double?
        if let lo = ires.first, let hi = ires.last, lo > 0, ires.count >= 2 {
            spreadStops = log2(hi / lo)
        } else {
            spreadStops = nil
        }
        snapshot = SoakLiveSnapshot(
            elapsed: startedAt.map { now.timeIntervalSince($0) } ?? 0,
            totalTicks: metrics.reduce(0) { $0 + $1.ticks },
            lockedTicks: accumulators.values.reduce(0) { $0 + $1.measurableTicks },
            hardFailedTicks: accumulators.values.reduce(0) { $0 + $1.hardFailedTicks },
            worstCenterJitterPixel: metrics.map(\.centerJitterPixel).max() ?? 0,
            worstIREStd: metrics.map(\.ireStd).max() ?? 0,
            pairwiseIRESpread: spreadIRE,
            pairwiseDisplayStops: spreadStops,
            cameras: metrics)
        lastSnapshotAt = now
    }

    private func summaryLines(reason: String, startedAt: Date, endedAt: Date,
                              csvURL: URL) -> [String] {
        var lines = [
            "R3DIRIS SPHERE SOAK SUMMARY",
            "started: \(Self.isoFormatter.string(from: startedAt))",
            "ended: \(Self.isoFormatter.string(from: endedAt))",
            "duration: \(Self.hms(endedAt.timeIntervalSince(startedAt)))",
            "reason: \(reason)",
            "csv: \(csvURL.path)",
            "ticks: \(snapshot.totalTicks)  locked_or_coasting: \(snapshot.lockedTicks)  hard_failed: \(snapshot.hardFailedTicks)",
        ]
        if let ire = snapshot.pairwiseIRESpread, let stops = snapshot.pairwiseDisplayStops {
            lines.append(String(format: "latest match readiness: %.3f IRE / %.4f display-referred stops",
                                locale: Locale(identifier: "en_US_POSIX"), ire, stops))
        }
        lines.append("")
        lines.append("PER CAMERA")
        for metric in snapshot.cameras {
            lines.append(String(format:
                "[%@] ticks=%d det=%.2f%% hard_fail=%.2f%% lock_uptime=%.2f%% center_sigma=%.3fpx max_excursion=%.3fpx radius_sigma=%.3fpx IRE_sigma=%.3f p5-p95=%@ relocks=%d%@",
                locale: Locale(identifier: "en_US_POSIX"),
                metric.cameraIP, metric.ticks, metric.detectionPercent,
                metric.hardFailPercent, metric.lockUptimePercent,
                metric.centerJitterPixel, metric.centerMaxExcursionPixel,
                metric.radiusJitterPixel, metric.ireStd,
                Self.range(metric.ireP5, metric.ireP95), metric.relockCount,
                Self.relockSuffix(metric)))
            if !metric.gateFailures.isEmpty {
                let hist = metric.gateFailures.keys.sorted()
                    .map { "\($0)=\(metric.gateFailures[$0] ?? 0)" }
                    .joined(separator: " ")
                lines.append("  gate failures: \(hist)")
            }
        }
        lines.append("")
        lines.append("EXPOSURE MATCH QA")
        lines.append("runs=\(matchQA.runs) rounds=\(matchQA.maxRound) direction_flips=\(matchQA.directionFlips) oscillations=\(matchQA.oscillations)")
        if !matchQA.nudgesByCamera.isEmpty {
            lines.append("nudges: " + matchQA.nudgesByCamera.keys.sorted()
                .map { "\($0)=\(matchQA.nudgesByCamera[$0] ?? 0)" }
                .joined(separator: " "))
        }
        if let ire = matchQA.finalSpreadIRE, let stops = matchQA.finalSpreadStops {
            lines.append(String(format: "final spread: %.3f IRE / %.4f stops",
                                locale: Locale(identifier: "en_US_POSIX"), ire, stops))
        }
        lines.append("")
        lines.append("verdict: inspect detection, jitter, relock, gate, and match-QA values against the active scene/harness settings")
        return lines
    }

    private func writeLine(_ line: String) throws {
        guard let fileHandle, let data = (line + "\n").data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileHandle.write(contentsOf: data)
        rowsSinceSync += 1
        if rowsSinceSync >= 100 {
            try fileHandle.synchronize()
            rowsSinceSync = 0
        }
    }

    private func csvLine(for row: SoakAnalysisRow) -> String {
        [
            "tick", Self.isoFormatter.string(from: row.timestamp), Self.csvEscape(row.cameraIP),
            String(row.tickSequence), Self.number(row.streamFPS), Self.number(row.analysisMS),
            row.phase.rawValue, Self.csvEscape(row.failureReason),
            Self.number(row.cxNorm), Self.number(row.cyNorm), Self.number(row.radiusNorm),
            Self.number(row.heroIRE), Self.number(row.chromaDistance), Self.number(row.shadowRatio),
            Self.number(row.interiorStd), Self.number(row.ireSpread), row.hardFailed ? "1" : "0",
            "", "", "", "", "", "", "",
        ].joined(separator: ",")
    }

    private static let csvHeader = [
        "row_type", "timestamp", "camera_ip", "tick_seq", "stream_fps", "analysis_ms",
        "phase", "fail_reason", "cx_norm", "cy_norm", "r_norm", "hero_ire",
        "chroma_dist", "shadow_ratio", "interior_std", "ire_spread", "hard_failed",
        "round", "nudges", "direction_flips", "final_spread_ire", "final_spread_stops",
        "event", "event_detail",
    ].joined(separator: ",")

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "nan" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func hms(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%dh%02dm%02ds", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func range(_ lo: Double?, _ hi: Double?) -> String {
        guard let lo, let hi else { return "n/a" }
        return String(format: "%.2f-%.2f", locale: Locale(identifier: "en_US_POSIX"), lo, hi)
    }

    private static func relockSuffix(_ metric: SoakCameraMetric) -> String {
        guard let p50 = metric.relockP50, let p95 = metric.relockP95 else { return "" }
        return String(format: " relock_p50=%.2fs relock_p95=%.2fs",
                      locale: Locale(identifier: "en_US_POSIX"), p50, p95)
    }
}

// MARK: - Constant-memory statistics

private struct RunningMoments {
    private(set) var count = 0
    private(set) var mean = 0.0
    private(set) var m2 = 0.0
    private(set) var minValue = Double.infinity
    private(set) var maxValue = -Double.infinity

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        m2 += delta * (value - mean)
        minValue = min(minValue, value)
        maxValue = max(maxValue, value)
    }

    var standardDeviation: Double { count > 0 ? sqrt(m2 / Double(count)) : 0 }
    var span: Double { count > 0 ? maxValue - minValue : 0 }
}

private struct FixedHistogram {
    let step: Double
    let maxValue: Double
    private(set) var bins: [Int]
    private(set) var count = 0

    init(step: Double, maxValue: Double) {
        self.step = step
        self.maxValue = maxValue
        self.bins = [Int](repeating: 0, count: Int((maxValue / step).rounded(.up)) + 1)
    }

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0), maxValue)
        let index = min(bins.count - 1, Int((clamped / step).rounded()))
        bins[index] += 1
        count += 1
    }

    func percentile(_ fraction: Double) -> Double? {
        guard count > 0 else { return nil }
        let target = max(1, Int(ceil(Double(count) * min(max(fraction, 0), 1))))
        var seen = 0
        for (index, value) in bins.enumerated() {
            seen += value
            if seen >= target { return Double(index) * step }
        }
        return maxValue
    }
}

private struct CameraAccumulator {
    private(set) var totalTicks = 0
    private(set) var measurableTicks = 0
    private(set) var hardFailedTicks = 0
    private var centerX = RunningMoments()
    private var centerY = RunningMoments()
    private var radius = RunningMoments()
    private var ire = RunningMoments()
    private var ireHistogram = FixedHistogram(step: 0.1, maxValue: 100)
    private var relockHistogram = FixedHistogram(step: 0.1, maxValue: 60)
    private var priorPhase: SphereState.Phase = .searching
    private var recoveryStartedAt: Date?
    private(set) var gateFailures: [String: Int] = [:]

    mutating func add(_ row: SoakAnalysisRow) {
        totalTicks += 1
        if row.phase == .locked || row.phase == .coasting { measurableTicks += 1 }
        if row.hardFailed { hardFailedTicks += 1 }
        if let x = row.centerXPixel { centerX.add(x) }
        if let y = row.centerYPixel { centerY.add(y) }
        if let r = row.radiusPixel { radius.add(r) }
        if let value = row.heroIRE {
            ire.add(value)
            ireHistogram.add(value)
        }
        if row.hardFailed, !row.failureReason.isEmpty {
            gateFailures[row.failureReason, default: 0] += 1
        }

        // Count recovery from the first coasting/searching tick after a lock;
        // this captures a two-second harness occlusion even when the track's
        // ten-miss grace period prevents a formal unlock.
        if priorPhase == .locked && row.phase != .locked {
            recoveryStartedAt = row.timestamp
        }
        if row.phase == .locked, let recoveryStartedAt {
            relockHistogram.add(row.timestamp.timeIntervalSince(recoveryStartedAt))
            self.recoveryStartedAt = nil
        }
        priorPhase = row.phase
    }

    func metric(cameraIP: String) -> SoakCameraMetric {
        let total = max(1, totalTicks)
        let jitter = hypot(centerX.standardDeviation, centerY.standardDeviation)
        let excursion = hypot(centerX.span, centerY.span)
        return SoakCameraMetric(
            cameraIP: cameraIP, ticks: totalTicks,
            detectionPercent: 100 * Double(measurableTicks) / Double(total),
            hardFailPercent: 100 * Double(hardFailedTicks) / Double(total),
            lockUptimePercent: 100 * Double(measurableTicks) / Double(total),
            centerJitterPixel: jitter,
            centerMaxExcursionPixel: excursion,
            radiusJitterPixel: radius.standardDeviation,
            ireStd: ire.standardDeviation,
            ireP5: ireHistogram.percentile(0.05),
            ireP95: ireHistogram.percentile(0.95),
            relockCount: relockHistogram.count,
            relockP50: relockHistogram.percentile(0.50),
            relockP95: relockHistogram.percentile(0.95),
            gateFailures: gateFailures)
    }
}

private struct MatchQAAccumulator {
    private(set) var runs = 0
    private(set) var maxRound = 0
    private(set) var nudgesByCamera: [String: Int] = [:]
    private(set) var directionFlips = 0
    private(set) var oscillations = 0
    private(set) var finalSpreadIRE: Double?
    private(set) var finalSpreadStops: Double?

    mutating func add(event: String, cameraIP: String, round: Int?, nudges: Int?,
                      directionFlips: Int?, finalSpreadIRE: Double?,
                      finalSpreadStops: Double?) {
        if event == "match_start" { runs += 1 }
        if let round { maxRound = max(maxRound, round) }
        if let nudges, !cameraIP.isEmpty { nudgesByCamera[cameraIP, default: 0] += nudges }
        self.directionFlips += directionFlips ?? 0
        if event == "oscillation" { oscillations += 1 }
        if let finalSpreadIRE { self.finalSpreadIRE = finalSpreadIRE }
        if let finalSpreadStops { self.finalSpreadStops = finalSpreadStops }
    }
}
