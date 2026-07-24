//  IREValidationController.swift — R3DIris
//  Main-actor state machine for the Bench MJPEG-vs-SDI evidence capture.

import Foundation
import SwiftUI
import AppKit

enum IREValidationFinalizeReason: Sendable, Equatable {
    case targetReached
    case operatorCancelled
    case qualityChanged
}

@MainActor
final class IREValidationController: ObservableObject {
    enum Phase: String, Equatable {
        case idle
        case preflighting
        case capturing
        case awaitingFinalReadback
        case processing
    }

    static let requiredFrameCount = 300

    @Published var subject: IREValidationSubject = .grayCard {
        didSet {
            if subject != oldValue {
                selection.points.removeAll()
                if subject == .colorChecker {
                    stage = .colorChecker
                } else if stage == .colorChecker {
                    stage = .gray18
                }
            }
        }
    }
    @Published var stage: IREValidationStage = .gray18
    @Published var nobeReferenceText = "33.3"
    @Published var nobeSignalRange: IREValidationSignalRange = .video
    @Published var operatorNote = ""
    @Published var selection = IREValidationSelection()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capturedFrames = 0
    @Published private(set) var statusText =
        "Create an evidence session, approve a native-frame ROI, then capture."
    @Published private(set) var lastResultText = ""
    @Published private(set) var sessionURL: URL?
    @Published private(set) var completedTrials = 0

    var onFinalizeRequested: ((IREValidationFinalizeReason) -> Void)?
    var onLog: ((String) -> Void)?

    private var sessionCreatedAt: Date?
    private var manifestTrials = [IREValidationManifestTrial]()
    private var activeConfig: IREValidationCaptureConfig?
    private var activeTrialDirectory: URL?
    private var rawFrames = [IREValidationRawFrame]()
    private var frameWriteTasks = [Task<String?, Never>]()
    private var pendingReason: IREValidationFinalizeReason = .targetReached
    private var sessionFinalized = false

    var isCapturing: Bool {
        phase == .capturing || phase == .awaitingFinalReadback
    }

    var isBusy: Bool { phase != .idle }
    /// An open session accepts trials. A finalized session remains revealable,
    /// but can never be reopened accidentally by another Capture.
    var hasSession: Bool { sessionURL != nil && !sessionFinalized }
    var canRevealSession: Bool { sessionURL != nil }

    var nobeReferenceIRE: Double? {
        guard let value = Double(nobeReferenceText.trimmingCharacters(in: .whitespaces)),
              value.isFinite, (-10...120).contains(value) else { return nil }
        return value
    }

    var selectionInstruction: String {
        let count = selection.points.count
        return "\(subject.pointInstruction) \(count)/\(subject.requiredPointCount) points."
    }

    var selectedNeutralLabel: String {
        IREColorChecker.name(for: selection.colorCheckerReferencePatch)
    }

    func chooseNewSession(benchLog: String) {
        guard !isBusy else {
            statusText = "Finish or cancel the active capture before creating a session."
            return
        }
        let panel = NSSavePanel()
        let stamp = Self.filenameTimestamp(Date())
        panel.title = "Create IRE Validation Evidence Folder"
        panel.prompt = "Create Session"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "r3diris_ire_validation_\(stamp).inprogress"
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let created = Date()
                try IREValidationExporter.createSession(at: url, createdAt: created, benchLog: benchLog)
                self.sessionURL = url
                self.sessionCreatedAt = created
                self.sessionFinalized = false
                self.manifestTrials.removeAll()
                self.completedTrials = 0
                self.lastResultText = ""
                self.statusText = "Evidence session ready. Select the subject and click the live image to approve the ROI."
                self.onLog?("IRE validation: evidence session created at \(url.path)")
            } catch {
                self.statusText = "Could not create evidence session: \(error.localizedDescription)"
                self.onLog?("IRE validation: session create failed — \(error.localizedDescription)")
            }
        }
    }

    func finishSession() {
        guard phase == .idle, hasSession,
              let root = sessionURL, let created = sessionCreatedAt else {
            statusText = "Wait for capture processing to finish before finalizing the session."
            return
        }
        let manifest = IREValidationManifest(
            createdAt: created,
            updatedAt: Date(),
            status: "complete",
            trials: manifestTrials
        )
        var destination = root
        if root.lastPathComponent.hasSuffix(".inprogress") {
            destination.deleteLastPathComponent()
            destination.appendPathComponent(
                String(root.lastPathComponent.dropLast(".inprogress".count)),
                isDirectory: true
            )
        }
        guard destination == root
                || !FileManager.default.fileExists(atPath: destination.path) else {
            statusText =
                "Session remains open at \(root.path): final destination already exists: " +
                destination.path
            return
        }

        var currentLocation = root
        var moved = false
        do {
            if destination != root {
                try FileManager.default.moveItem(at: root, to: destination)
                currentLocation = destination
                moved = true
            }
            // Establish the final path before certifying the manifest. A move
            // failure therefore leaves `.inprogress` explicitly in progress.
            try IREValidationExporter.writeManifest(manifest, root: currentLocation)
            sessionURL = currentLocation
            sessionFinalized = true
            statusText = "Session finalized: \(destination.lastPathComponent)"
            onLog?("IRE validation: session finalized at \(destination.path)")
        } catch {
            let primaryError = error.localizedDescription
            var rollbackNote = ""
            if moved {
                do {
                    try FileManager.default.moveItem(at: currentLocation, to: root)
                    currentLocation = root
                } catch {
                    rollbackNote = " Rollback also failed: \(error.localizedDescription)"
                }
            }
            sessionURL = currentLocation
            sessionFinalized = false
            statusText =
                "Session remains recoverable at \(currentLocation.path): " +
                "\(primaryError).\(rollbackNote)"
            onLog?("IRE validation: finalize failed; partial retained — \(statusText)")
        }
    }

    func revealSession() {
        guard let sessionURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sessionURL])
    }

    func reportIssue(_ text: String) {
        statusText = text
    }

    /// Claim the evidence state synchronously before asynchronous camera reads.
    /// This closes the double-Capture window and lets Bench lock camera/stream
    /// controls for the entire metadata preflight.
    @discardableResult
    func beginPreflight(_ text: String) -> Bool {
        guard phase == .idle else { return false }
        phase = .preflighting
        capturedFrames = 0
        statusText = text
        return true
    }

    func endPreflight(_ text: String) {
        guard phase == .preflighting else { return }
        phase = .idle
        statusText = text
    }

    func resetSelection() {
        guard phase == .idle else { return }
        selection.points.removeAll()
        statusText = subject.pointInstruction
    }

    func addSelectionPoint(_ point: IRENormalizedPoint) {
        guard phase == .idle else { return }
        if selection.points.count >= subject.requiredPointCount {
            selection.points.removeAll()
        }
        selection.points.append(point)
        if selection.isComplete(for: subject) {
            statusText = "ROI approved. Prepare the matching Nobe waveform reference."
        } else {
            statusText = selectionInstruction
        }
    }

    @discardableResult
    func beginCapture(ip: String,
                      cameraStatus: CameraStatus,
                      streamStats: MJPEGStreamReader.Stats,
                      streamIsLive: Bool,
                      requestedQuality: Int?) -> Bool {
        guard phase == .preflighting else { return false }
        guard hasSession, let root = sessionURL else {
            return rejectCapture(
                "Create an evidence session first; unfinished work is retained there."
            )
        }
        guard streamIsLive else {
            return rejectCapture("Enable the port-9090 livestream and wait for a frame.")
        }
        guard streamStats.width == 1920, streamStats.height == 1080 else {
            return rejectCapture(
                "Validation requires the native 1920×1080 stream; current readback is " +
                "\(streamStats.width)×\(streamStats.height)."
            )
        }
        guard cameraStatus.link == .connected else {
            return rejectCapture("The RCP2 camera session disconnected during capture preflight.")
        }
        guard let quality = cameraStatus.livestreamQuality else {
            return rejectCapture(
                "Read/set Livestream Quality first. Capture requires an actual camera read-back."
            )
        }
        guard !cameraStatus.livestreamQualityOptions.isEmpty else {
            return rejectCapture(
                "The camera did not return its LIVESTREAM_QUALITY list; permitted factors are unverified."
            )
        }
        guard cameraStatus.livestreamQualityOptions.contains(where: {
            $0.value == quality
        }) else {
            return rejectCapture(
                "Actual livestream quality \(quality) is not present in the camera-advertised list."
            )
        }
        let minimumFreeBytes: Int64 = 500 * 1024 * 1024
        do {
            let values = try root.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            guard let available = values.volumeAvailableCapacityForImportantUsage else {
                return rejectCapture(
                    "Could not verify free space on the evidence destination; capture was not started."
                )
            }
            guard available >= minimumFreeBytes else {
                return rejectCapture(
                    "Capture needs at least 500 MiB free for raw/partial evidence; destination has " +
                    "\(Self.byteCount(available)). Free space or choose another volume."
                )
            }
        } catch {
            return rejectCapture(
                "Could not verify destination capacity: \(error.localizedDescription)"
            )
        }
        guard cameraStatus.monitorTransform == .log3G10 else {
            return rejectCapture(
                "Read the active mirror transform first; validation requires actual Log3G10 read-back."
            )
        }
        guard let mirrorSource = cameraStatus.mirrorSource,
              (1...3).contains(mirrorSource) else {
            return rejectCapture(
                "Validation requires an actual livestream mirror-source read-back (SDI-1, SDI-2, or Top LCD)."
            )
        }
        guard RCP2.monitorDisplayPresetCandidates(forMirrorSource: mirrorSource)
            .contains(cameraStatus.monitorTransformParam) else {
            return rejectCapture(
                "The Log3G10 read-back did not come from the output feeding port 9090; refresh camera metadata."
            )
        }
        guard !cameraStatus.rectPixels.isEmpty else {
            return rejectCapture(
                "Validation requires a fresh LIVESTREAM_RECT_PIXELS read-back before capture."
            )
        }
        let stageMatchesSubject = subject == .colorChecker
            ? stage == .colorChecker
            : stage != .colorChecker
        guard stageMatchesSubject else {
            return rejectCapture("Choose a stage that matches the selected validation subject.")
        }
        guard selection.isComplete(for: subject) else {
            return rejectCapture(selectionInstruction)
        }
        guard let nobe = nobeReferenceIRE else {
            return rejectCapture("Enter the simultaneous Nobe/10-bit SDI value in IRE.")
        }

        let now = Date()
        let trialID =
            "\(Self.filenameTimestamp(now))_\(subject.rawValue)_q\(quality)_" +
            String(UUID().uuidString.prefix(8))
        let camera = IREValidationCameraSnapshot(
            ip: ip,
            name: cameraStatus.name,
            serial: cameraStatus.serial,
            firmware: cameraStatus.firmware,
            clipName: cameraStatus.clipName,
            qualityRequestedValue: requestedQuality ?? quality,
            qualityRequestSource: requestedQuality == nil
                ? "current_actual_readback"
                : "operator_requested_in_R3DIris",
            qualityValue: quality,
            qualityLabel: RCP2.livestreamQualityLabels[quality] ?? "VALUE \(quality)",
            qualityOptions: cameraStatus.livestreamQualityOptions,
            mirrorSourceValue: cameraStatus.mirrorSource,
            mirrorSourceLabel: cameraStatus.mirrorSource
                .flatMap { RCP2.mirrorSourceLabels[$0] } ?? "UNKNOWN",
            livestreamRectRaw: cameraStatus.rectPixels,
            monitorTransform: cameraStatus.monitorTransform.rawValue,
            monitorTransformParameter: cameraStatus.monitorTransformParam,
            monitorTransformValue: cameraStatus.monitorTransformValue
        )
        let appVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let config = IREValidationCaptureConfig(
            trialID: trialID,
            subject: subject,
            stage: stage,
            requestedFrames: Self.requiredFrameCount,
            nobeReferenceIRE: nobe,
            nobeSignalRange: nobeSignalRange,
            nobeReferenceConfirmedAt: now,
            operatorNote: operatorNote,
            selection: selection,
            camera: camera,
            streamWidth: streamStats.width,
            streamHeight: streamStats.height,
            startedAt: now,
            appVersion: appVersion
        )

        do {
            activeTrialDirectory = try IREValidationExporter.createTrial(config: config, root: root)
        } catch {
            return rejectCapture(
                "Could not create the recoverable trial folder: \(error.localizedDescription)"
            )
        }

        activeConfig = config
        rawFrames.removeAll(keepingCapacity: true)
        rawFrames.reserveCapacity(Self.requiredFrameCount)
        frameWriteTasks.removeAll(keepingCapacity: true)
        capturedFrames = 0
        pendingReason = .targetReached
        phase = .capturing
        statusText = "Capturing 300 exact JPEGs. Keep the Nobe pin and exposure unchanged."
        onLog?(
            "IRE validation: capture \(trialID) started at \(camera.qualityLabel) " +
            "(actual read-back \(quality)), Nobe \(String(format: "%.3f", nobe)) IRE"
        )
        return true
    }

    /// Called directly from MJPEGStreamReader's exact-JPEG tap. It only keeps a
    /// bounded Data copy and schedules an atomic raw write; analysis never runs
    /// on the main-actor stream callback.
    func receiveJPEG(_ jpeg: Data, at receivedAt: Date, cameraStatus: CameraStatus) {
        guard phase == .capturing, let config = activeConfig, let directory = activeTrialDirectory else {
            return
        }
        guard cameraStatus.livestreamQuality == config.camera.qualityValue else {
            pendingReason = .qualityChanged
            phase = .awaitingFinalReadback
            statusText =
                "Quality no longer matches the approved actual read-back. Keeping the partial trial."
            onFinalizeRequested?(.qualityChanged)
            return
        }

        let index = rawFrames.count + 1
        let frame = IREValidationRawFrame(index: index, receivedAt: receivedAt, jpeg: jpeg)
        rawFrames.append(frame)
        capturedFrames = rawFrames.count
        frameWriteTasks.append(Task.detached(priority: .utility) {
            IREValidationExporter.writeRawFrame(frame, to: directory)
        })

        if rawFrames.count >= config.requestedFrames {
            pendingReason = .targetReached
            phase = .awaitingFinalReadback
            statusText = "300/300 captured. Verifying final camera quality read-back…"
            onFinalizeRequested?(.targetReached)
        } else if rawFrames.count % 25 == 0 {
            statusText = "Capturing exact JPEGs: \(rawFrames.count)/\(config.requestedFrames)"
        }
    }

    func requestCancel() {
        guard phase == .capturing else { return }
        pendingReason = .operatorCancelled
        phase = .awaitingFinalReadback
        statusText = "Stopping capture; the partial raw evidence will be analyzed and retained."
        onFinalizeRequested?(.operatorCancelled)
    }

    func finishCapture(endStatus: CameraStatus, benchLog: String) {
        guard phase == .awaitingFinalReadback,
              let root = sessionURL,
              let created = sessionCreatedAt,
              let config = activeConfig else { return }
        phase = .processing

        let frames = rawFrames
        let writes = frameWriteTasks
        let reason = pendingReason
        let endQuality = endStatus.livestreamQuality
        let qualityMatches = endQuality == config.camera.qualityValue
        let mirrorMatches = endStatus.mirrorSource == config.camera.mirrorSourceValue
        let transformMatches =
            endStatus.monitorTransform == .log3G10
                && endStatus.monitorTransformParam == config.camera.monitorTransformParameter
                && endStatus.monitorTransformValue == config.camera.monitorTransformValue
        let rectMatches =
            !endStatus.rectPixels.isEmpty
                && endStatus.rectPixels == config.camera.livestreamRectRaw
        statusText = "Analyzing \(frames.count) native 1920×1080 frames…"

        Task {
            var writeErrors = [String]()
            for write in writes {
                if let error = await write.value { writeErrors.append(error) }
            }
            let analysis = await Task.detached(priority: .utility) {
                IREValidationAnalyzer.analyze(frames: frames, config: config)
            }.value

            let expectedSummaries =
                config.subject == .colorChecker ? IREColorChecker.patchNames.count : 1
            let analysisComplete =
                analysis.decodeFailures == 0
                    && analysis.analysisErrors.isEmpty
                    && analysis.summaries.count == expectedSummaries
                    && analysis.summaries.allSatisfy {
                        $0.measuredFrames == config.requestedFrames
                    }
            let trialStatus: String
            if !qualityMatches || reason == .qualityChanged {
                trialStatus = "invalid_quality_changed"
            } else if !mirrorMatches || !transformMatches || !rectMatches {
                trialStatus = "invalid_camera_state_changed"
            } else if reason == .operatorCancelled || frames.count < config.requestedFrames {
                trialStatus = "cancelled_partial"
            } else if !writeErrors.isEmpty {
                trialStatus = "invalid_raw_evidence"
            } else if !analysisComplete {
                trialStatus = "invalid_analysis"
            } else {
                trialStatus = "complete"
            }
            let endLabel = endQuality.flatMap { RCP2.livestreamQualityLabels[$0] } ?? "NO READ-BACK"
            var allErrors = writeErrors + analysis.analysisErrors
            if !qualityMatches {
                allErrors.insert(
                    "Actual quality changed from \(config.camera.qualityLabel) to \(endLabel).",
                    at: 0
                )
            }
            if !mirrorMatches {
                allErrors.append(
                    "Livestream mirror source changed or lost read-back during capture."
                )
            }
            if !transformMatches {
                allErrors.append(
                    "The mirrored output's Log3G10 transform changed or lost read-back during capture."
                )
            }
            if !rectMatches {
                allErrors.append(
                    "LIVESTREAM_RECT_PIXELS changed during capture."
                )
            }
            if !analysisComplete, analysis.analysisErrors.isEmpty {
                allErrors.append(
                    "Expected \(expectedSummaries) complete native ROI summaries; received " +
                    "\(analysis.summaries.count) with \(analysis.decodeFailures) decode failures."
                )
            }
            let trial = IREValidationManifestTrial(
                config: config,
                completedAt: Date(),
                capturedFrames: frames.count,
                status: trialStatus,
                endQualityValue: endQuality,
                endQualityLabel: endLabel,
                endMirrorSourceValue: endStatus.mirrorSource,
                endMonitorTransform: endStatus.monitorTransform.rawValue,
                endMonitorTransformParameter: endStatus.monitorTransformParam,
                endMonitorTransformValue: endStatus.monitorTransformValue,
                endLivestreamRectRaw: endStatus.rectPixels,
                decodeFailures: analysis.decodeFailures,
                rawDirectory: "raw/\(config.trialID)",
                errors: allErrors,
                summaries: analysis.summaries
            )
            var updatedTrials = manifestTrials
            updatedTrials.append(trial)
            let manifest = IREValidationManifest(
                createdAt: created,
                updatedAt: Date(),
                status: "in_progress",
                trials: updatedTrials
            )
            let exported = await Task.detached(priority: .utility) {
                IREValidationExporter.finishTrial(
                    root: root,
                    manifest: manifest,
                    trial: trial,
                    result: analysis,
                    benchLog: benchLog
                )
            }.value

            var finalTrial = trial
            var finalTrials = updatedTrials
            var exportErrors = exported.errors
            if !exportErrors.isEmpty {
                finalTrial.status = finalTrial.status == "complete"
                    ? "invalid_export"
                    : "\(finalTrial.status)_export_failed"
                finalTrial.errors.append(contentsOf: exportErrors)
                finalTrials[finalTrials.count - 1] = finalTrial
                let correctedTrial = finalTrial
                let correctedManifest = IREValidationManifest(
                    createdAt: created,
                    updatedAt: Date(),
                    status: "in_progress",
                    trials: finalTrials
                )
                let rewrite = await Task.detached(priority: .utility) {
                    IREValidationExporter.rewriteFinalState(
                        root: root,
                        manifest: correctedManifest,
                        trial: correctedTrial
                    )
                }.value
                exportErrors.append(contentsOf: rewrite.errors)
            }

            manifestTrials = finalTrials
            completedTrials = manifestTrials.count
            phase = .idle
            activeConfig = nil
            activeTrialDirectory = nil
            rawFrames.removeAll()
            frameWriteTasks.removeAll()

            if let referenceSummary = analysis.summaries.first(where: {
                config.subject != .colorChecker
                    || $0.patchIndex == config.selection.colorCheckerReferencePatch
            }) {
                if let production = referenceSummary.productionMeanIRE {
                    let bias = referenceSummary.productionBiasIRE
                        .map { String(format: "%+.3f", $0) } ?? "—"
                    lastResultText =
                        "App estimator \(String(format: "%.3f", production)) IRE · " +
                        "Nobe \(String(format: "%.3f", config.nobeReferenceIRE)) · " +
                        "bias \(bias) IRE · zero-inclusive diagnostic " +
                        "\(String(format: "%.3f", referenceSummary.meanIRE))"
                } else {
                    lastResultText =
                        "App estimator unavailable (no non-zero samples) · " +
                        "zero-inclusive MJPEG \(String(format: "%.3f", referenceSummary.meanIRE)) IRE · " +
                        "Nobe \(String(format: "%.3f", config.nobeReferenceIRE))"
                }
            } else {
                lastResultText = "No valid native ROI measurements were produced."
            }

            if exportErrors.isEmpty {
                statusText =
                    "\(finalTrial.status.replacingOccurrences(of: "_", with: " ")); evidence saved. " +
                    "Repeat at every camera-advertised quality."
            } else {
                statusText =
                    "Raw evidence retained, but export reported: \(exportErrors.joined(separator: "; "))"
            }
            onLog?(
                "IRE validation: \(config.trialID) \(finalTrial.status), \(frames.count) frames, " +
                "\(analysis.decodeFailures) decode failures. \(lastResultText)"
            )
        }
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    @discardableResult
    private func rejectCapture(_ text: String) -> Bool {
        statusText = text
        if phase == .preflighting { phase = .idle }
        return false
    }
}
