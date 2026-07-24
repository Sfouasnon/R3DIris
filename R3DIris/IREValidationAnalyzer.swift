//  IREValidationAnalyzer.swift — R3DIris
//  Native-dimension MJPEG measurement and evidence-bundle serialization for
//  the Bench IRE validation workflow.

import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

enum IREValidationAnalyzer {
    static func analyze(frames: [IREValidationRawFrame],
                        config: IREValidationCaptureConfig) -> IREValidationAnalysisResult {
        var measurements = [IREFrameMeasurement]()
        var failures = 0
        var errors = [String]()
        let homography = config.subject == .colorChecker
            ? IREChartHomography(corners: config.selection.points)
            : nil

        if config.subject == .colorChecker, homography == nil {
            return IREValidationAnalysisResult(
                measurements: [],
                summaries: [],
                decodeFailures: frames.count,
                analysisErrors: ["The four ColorChecker corners did not produce a valid projective transform."]
            )
        }

        for rawFrame in frames {
            guard let source = CGImageSourceCreateWithData(rawFrame.jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                failures += 1
                errors.append("Frame \(rawFrame.index): ImageIO could not decode the exact JPEG payload.")
                continue
            }
            guard image.width == config.streamWidth, image.height == config.streamHeight else {
                failures += 1
                errors.append(
                    "Frame \(rawFrame.index): dimensions changed from approved " +
                    "\(config.streamWidth)×\(config.streamHeight) to \(image.width)×\(image.height); skipped."
                )
                continue
            }
            guard let raster = NativeValidationRaster(image: image) else {
                failures += 1
                errors.append("Frame \(rawFrame.index): native sRGB rasterization failed.")
                continue
            }

            let hash = SHA256.hash(data: rawFrame.jpeg).map { String(format: "%02x", $0) }.joined()
            let regions: [(Int?, String, NativeValidationRegion)]
            switch config.subject {
            case .grayCard:
                let points = config.selection.points
                guard points.count == 2 else { continue }
                regions = [(nil, "Approved card ROI", .rectangle(points[0], points[1]))]
            case .graySphere:
                guard let center = config.selection.points.first else { continue }
                regions = [(
                    nil,
                    "Sphere center probe",
                    .disk(center: center,
                          radiusNormalizedToWidth: config.selection.sphereOuterRadius * 0.24)
                )]
            case .colorChecker:
                regions = (0..<IREColorChecker.patchNames.count).compactMap { index in
                    guard let quad = homography?.patchQuad(index: index) else { return nil }
                    return (index, IREColorChecker.name(for: index), .quadrilateral(quad))
                }
            }

            for (patchIndex, patchName, region) in regions {
                guard let sample = raster.measure(region: region) else {
                    errors.append("Frame \(rawFrame.index), \(patchName): ROI contained no native pixels.")
                    continue
                }
                measurements.append(IREFrameMeasurement(
                    frameIndex: rawFrame.index,
                    receivedAt: rawFrame.receivedAt,
                    jpegBytes: rawFrame.jpeg.count,
                    jpegSHA256: hash,
                    nativeWidth: image.width,
                    nativeHeight: image.height,
                    sourceColorSpace: raster.sourceColorSpace,
                    patchIndex: patchIndex,
                    patchName: patchName,
                    sampleCount: sample.count,
                    zeroCount: sample.zeroCount,
                    clippedCount: sample.clippedCount,
                    productionSampleCount: sample.productionSampleCount,
                    productionIRE: sample.productionIRE,
                    meanRedIRE: sample.meanRedIRE,
                    meanGreenIRE: sample.meanGreenIRE,
                    meanBlueIRE: sample.meanBlueIRE,
                    meanLumaIRE: sample.meanLumaIRE,
                    medianLumaIRE: sample.medianLumaIRE,
                    p05LumaIRE: sample.p05LumaIRE,
                    p95LumaIRE: sample.p95LumaIRE
                ))
            }
        }

        let summaries = summarize(measurements: measurements, config: config)
        return IREValidationAnalysisResult(
            measurements: measurements,
            summaries: summaries,
            decodeFailures: failures,
            analysisErrors: Array(errors.prefix(100))
        )
    }

    private static func summarize(measurements: [IREFrameMeasurement],
                                  config: IREValidationCaptureConfig) -> [IRETrialSummary] {
        let grouped = Dictionary(grouping: measurements) { measurement in
            measurement.patchIndex ?? -1
        }
        return grouped.keys.sorted().compactMap { key in
            guard let rows = grouped[key], !rows.isEmpty else { return nil }
            let values = rows.map(\.medianLumaIRE)
            let mean = values.reduce(0, +) / Double(values.count)
            let median = percentile(values, fraction: 0.5)
            let variance: Double
            if values.count > 1 {
                variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
            } else {
                variance = 0
            }
            let absoluteDeviations = values.map { abs($0 - median) }

            let firstDate = rows.map(\.receivedAt).min() ?? config.startedAt
            let blocks = Dictionary(grouping: rows) {
                max(0, Int($0.receivedAt.timeIntervalSince(firstDate).rounded(.down)))
            }
            let blockMeans = blocks.keys.sorted().compactMap { block -> Double? in
                guard let members = blocks[block], !members.isEmpty else { return nil }
                return members.map(\.medianLumaIRE).reduce(0, +) / Double(members.count)
            }
            let blockMean = blockMeans.isEmpty ? 0 : blockMeans.reduce(0, +) / Double(blockMeans.count)
            let blockVariance: Double
            if blockMeans.count > 1 {
                blockVariance = blockMeans.reduce(0) { $0 + pow($1 - blockMean, 2) }
                    / Double(blockMeans.count - 1)
            } else {
                blockVariance = 0
            }

            let patchIndex = rows[0].patchIndex
            let carriesReference: Bool
            if config.subject == .colorChecker {
                carriesReference = patchIndex == config.selection.colorCheckerReferencePatch
            } else {
                carriesReference = true
            }
            let reference = carriesReference ? config.nobeReferenceIRE : nil
            let bias = reference.map { mean - $0 }
            var stopError: Double? = nil
            if let reference, reference > 0, mean > 0 {
                let value = Log3G10.stops(between: reference, and: mean)
                if value.isFinite { stopError = value }
            }

            let productionValues = rows.compactMap(\.productionIRE)
            let productionMean: Double? = productionValues.isEmpty
                ? nil
                : productionValues.reduce(0, +) / Double(productionValues.count)
            let productionMedian = productionValues.isEmpty
                ? nil
                : percentile(productionValues, fraction: 0.5)
            let productionSD: Double?
            if let productionMean, productionValues.count > 1 {
                let variance = productionValues.reduce(0) {
                    $0 + pow($1 - productionMean, 2)
                } / Double(productionValues.count - 1)
                productionSD = sqrt(variance)
            } else if productionValues.count == 1 {
                productionSD = 0
            } else {
                productionSD = nil
            }
            var productionBias: Double?
            var productionStopError: Double?
            if let reference, let productionMean {
                productionBias = productionMean - reference
                if reference > 0, productionMean > 0 {
                    let value = Log3G10.stops(between: reference, and: productionMean)
                    if value.isFinite { productionStopError = value }
                }
            }

            return IRETrialSummary(
                patchIndex: patchIndex,
                patchName: rows[0].patchName,
                measuredFrames: rows.count,
                totalPixelSamples: rows.reduce(0) { $0 + $1.sampleCount },
                meanIRE: mean,
                medianIRE: median,
                standardDeviationIRE: sqrt(variance),
                madIRE: percentile(absoluteDeviations, fraction: 0.5),
                p05IRE: percentile(values, fraction: 0.05),
                p95IRE: percentile(values, fraction: 0.95),
                oneSecondBlockCount: blockMeans.count,
                oneSecondBlockMeanSDIRE: sqrt(blockVariance),
                nobeReferenceIRE: reference,
                biasIRE: bias,
                log3G10StopError: stopError,
                productionMeasuredFrames: productionValues.count,
                productionMeanIRE: productionMean,
                productionMedianIRE: productionMedian,
                productionStandardDeviationIRE: productionSD,
                productionBiasIRE: productionBias,
                productionLog3G10StopError: productionStopError
            )
        }
    }

    fileprivate static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let blend = position - Double(lower)
        return sorted[lower] * (1 - blend) + sorted[upper] * blend
    }
}

private enum NativeValidationRegion {
    case rectangle(IRENormalizedPoint, IRENormalizedPoint)
    case disk(center: IRENormalizedPoint, radiusNormalizedToWidth: Double)
    case quadrilateral([IRENormalizedPoint])
}

private struct NativeValidationSample {
    var count: Int
    var zeroCount: Int
    var clippedCount: Int
    var productionSampleCount: Int
    var productionIRE: Double?
    var meanRedIRE: Double
    var meanGreenIRE: Double
    var meanBlueIRE: Double
    var meanLumaIRE: Double
    var medianLumaIRE: Double
    var p05LumaIRE: Double
    var p95LumaIRE: Double
}

/// One full-resolution working raster per frame. Detection elsewhere remains
/// downscaled; this validation path deliberately measures approved regions in
/// the camera's native 1920×1080 JPEG decode. Zero and clipped pixels are kept.
private struct NativeValidationRaster {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    let sourceColorSpace: String

    init?(image: CGImage) {
        let rasterWidth = image.width
        let rasterHeight = image.height
        let sourceSpaceName: String
        if let name = image.colorSpace?.name {
            sourceSpaceName = name as String
        } else {
            sourceSpaceName = "unknown"
        }
        var bytes = [UInt8](repeating: 0, count: rasterWidth * rasterHeight * 4)
        guard let workingSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rendered: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: rasterWidth,
                height: rasterHeight,
                bitsPerComponent: 8,
                bytesPerRow: rasterWidth * 4,
                space: workingSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: rasterWidth, height: rasterHeight)
            )
            return true
        }
        guard rendered else { return nil }
        width = rasterWidth
        height = rasterHeight
        sourceColorSpace = sourceSpaceName
        rgba = bytes
    }

    func measure(region: NativeValidationRegion) -> NativeValidationSample? {
        let bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)
        switch region {
        case let .rectangle(a, b):
            bounds = pixelBounds(points: [a, b])
        case let .disk(center, radius):
            let radiusPixels = radius * Double(width)
            bounds = (
                max(0, Int((center.x * Double(width) - radiusPixels).rounded(.down))),
                min(width - 1, Int((center.x * Double(width) + radiusPixels).rounded(.up))),
                max(0, Int((center.y * Double(height) - radiusPixels).rounded(.down))),
                min(height - 1, Int((center.y * Double(height) + radiusPixels).rounded(.up)))
            )
        case let .quadrilateral(points):
            bounds = pixelBounds(points: points)
        }
        guard bounds.minX <= bounds.maxX, bounds.minY <= bounds.maxY else { return nil }

        var lumaValues = [Double]()
        lumaValues.reserveCapacity((bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1))
        var productionLuma = [Float]()
        productionLuma.reserveCapacity(lumaValues.capacity)
        var redTotal = 0.0, greenTotal = 0.0, blueTotal = 0.0, lumaTotal = 0.0
        var zeros = 0, clipped = 0

        for y in bounds.minY...bounds.maxY {
            for x in bounds.minX...bounds.maxX {
                guard contains(pixelX: x, pixelY: y, region: region) else { continue }
                let offset = (y * width + x) * 4
                let red = Double(rgba[offset]) / 255.0
                let green = Double(rgba[offset + 1]) / 255.0
                let blue = Double(rgba[offset + 2]) / 255.0
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                redTotal += red
                greenTotal += green
                blueTotal += blue
                lumaTotal += luma
                lumaValues.append(luma * 100)
                let productionRed = Float(rgba[offset]) / 255.0
                let productionGreen = Float(rgba[offset + 1]) / 255.0
                let productionBlue = Float(rgba[offset + 2]) / 255.0
                productionLuma.append(
                    0.2126 * productionRed
                        + 0.7152 * productionGreen
                        + 0.0722 * productionBlue
                )
                if rgba[offset] == 0, rgba[offset + 1] == 0, rgba[offset + 2] == 0 {
                    zeros += 1
                }
                if rgba[offset] == 255, rgba[offset + 1] == 255, rgba[offset + 2] == 255 {
                    clipped += 1
                }
            }
        }

        let count = lumaValues.count
        guard count > 0 else { return nil }
        let production = NativeIREProbe.productionEstimate(
            fromNormalizedLuma: productionLuma
        )
        return NativeValidationSample(
            count: count,
            zeroCount: zeros,
            clippedCount: clipped,
            productionSampleCount: production?.nonzeroSampleCount ?? 0,
            productionIRE: production?.ire,
            meanRedIRE: redTotal / Double(count) * 100,
            meanGreenIRE: greenTotal / Double(count) * 100,
            meanBlueIRE: blueTotal / Double(count) * 100,
            meanLumaIRE: lumaTotal / Double(count) * 100,
            medianLumaIRE: IREValidationAnalyzer.percentile(lumaValues, fraction: 0.5),
            p05LumaIRE: IREValidationAnalyzer.percentile(lumaValues, fraction: 0.05),
            p95LumaIRE: IREValidationAnalyzer.percentile(lumaValues, fraction: 0.95)
        )
    }

    private func pixelBounds(points: [IRENormalizedPoint])
        -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let xs = points.map { $0.x * Double(width) }
        let ys = points.map { $0.y * Double(height) }
        return (
            max(0, Int((xs.min() ?? 0).rounded(.down))),
            min(width - 1, Int((xs.max() ?? 0).rounded(.up))),
            max(0, Int((ys.min() ?? 0).rounded(.down))),
            min(height - 1, Int((ys.max() ?? 0).rounded(.up)))
        )
    }

    private func contains(pixelX x: Int, pixelY y: Int,
                          region: NativeValidationRegion) -> Bool {
        switch region {
        case let .rectangle(a, b):
            let point = IRENormalizedPoint(
                x: (Double(x) + 0.5) / Double(width),
                y: (Double(y) + 0.5) / Double(height)
            )
            return point.x >= min(a.x, b.x) && point.x <= max(a.x, b.x)
                && point.y >= min(a.y, b.y) && point.y <= max(a.y, b.y)
        case let .disk(center, radius):
            // Match NativeIREProbe exactly: its production disk tests integer
            // pixel coordinates, not pixel centers.
            let dx = Double(x) - center.x * Double(width)
            let dy = Double(y) - center.y * Double(height)
            let radiusPixels = radius * Double(width)
            return dx * dx + dy * dy <= radiusPixels * radiusPixels
        case let .quadrilateral(points):
            guard points.count == 4 else { return false }
            let point = IRENormalizedPoint(
                x: (Double(x) + 0.5) / Double(width),
                y: (Double(y) + 0.5) / Double(height)
            )
            var sign = 0.0
            for index in 0..<4 {
                let a = points[index]
                let b = points[(index + 1) % 4]
                let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                if abs(cross) < 1e-12 { continue }
                if sign == 0 {
                    sign = cross
                } else if cross * sign < 0 {
                    return false
                }
            }
            return true
        }
    }
}

enum IREValidationExporter {
    struct ExportResult: Sendable {
        var errors: [String]
    }

    static func createSession(at root: URL, createdAt: Date, benchLog: String) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            throw NSError(
                domain: "R3DIris.IREValidation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "That path already exists. Choose a new evidence-session name."]
            )
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = IREValidationManifest(
            createdAt: createdAt,
            updatedAt: createdAt,
            status: "in_progress",
            trials: []
        )
        try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
        try benchLog.write(
            to: root.appendingPathComponent("bench.log"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func createTrial(config: IREValidationCaptureConfig, root: URL) throws -> URL {
        let trialDirectory = root
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent(config.trialID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: trialDirectory.path) else {
            throw NSError(
                domain: "R3DIris.IREValidation",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Trial evidence path already exists; no files were overwritten."]
            )
        }
        try FileManager.default.createDirectory(at: trialDirectory, withIntermediateDirectories: true)
        let state = [
            "status": "capturing",
            "trial_id": config.trialID,
            "started_at": iso(config.startedAt),
            "requested_frames": String(config.requestedFrames),
            "quality_requested": String(config.camera.qualityRequestedValue),
            "quality_actual_readback": String(config.camera.qualityValue),
            "quality_advertised_options": config.camera.qualityOptions
                .map { "\($0.label)=\($0.value)" }
                .joined(separator: "|"),
        ]
        try writeJSON(state, to: trialDirectory.appendingPathComponent("capture-state.json"))
        return trialDirectory
    }

    static func writeRawFrame(_ frame: IREValidationRawFrame, to trialDirectory: URL) -> String? {
        let name = String(format: "frame_%04d.jpg", frame.index)
        do {
            try frame.jpeg.write(to: trialDirectory.appendingPathComponent(name), options: .atomic)
            return nil
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }

    static func finishTrial(root: URL,
                            manifest: IREValidationManifest,
                            trial: IREValidationManifestTrial,
                            result: IREValidationAnalysisResult,
                            benchLog: String) -> ExportResult {
        var errors = [String]()
        do {
            try appendFrames(result.measurements, config: trial.config,
                             to: root.appendingPathComponent("frames.csv"))
        } catch {
            errors.append("frames.csv: \(error.localizedDescription)")
        }
        do {
            try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
        } catch {
            errors.append("manifest.json: \(error.localizedDescription)")
        }
        do {
            try benchLog.write(
                to: root.appendingPathComponent("bench.log"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errors.append("bench.log: \(error.localizedDescription)")
        }
        do {
            let trialDirectory = root
                .appendingPathComponent("raw", isDirectory: true)
                .appendingPathComponent(trial.config.trialID, isDirectory: true)
            try writeJSON(trial, to: trialDirectory.appendingPathComponent("capture-state.json"))
        } catch {
            errors.append("capture-state.json: \(error.localizedDescription)")
        }
        // Never certify a trial in the summary CSV before every other evidence
        // export has succeeded. The controller changes the trial to
        // `invalid_export` when this result contains an error; its correction
        // pass then writes the complete summary snapshot with that final status.
        if errors.isEmpty {
            do {
                try writeSummaries(manifest.trials,
                                   to: root.appendingPathComponent("trials.csv"))
            } catch {
                errors.append("trials.csv: \(error.localizedDescription)")
            }
        }
        return ExportResult(errors: errors)
    }

    /// Rewrite final state after an export failure changes the trial's
    /// certification status. `trials.csv` is an atomic snapshot of the manifest
    /// rather than an append-only log, so it can never retain an earlier
    /// `complete` row after the JSON state says `invalid_export`.
    static func rewriteFinalState(root: URL,
                                  manifest: IREValidationManifest,
                                  trial: IREValidationManifestTrial) -> ExportResult {
        var errors = [String]()
        do {
            try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
        } catch {
            errors.append("manifest status rewrite: \(error.localizedDescription)")
        }
        do {
            let trialDirectory = root
                .appendingPathComponent("raw", isDirectory: true)
                .appendingPathComponent(trial.config.trialID, isDirectory: true)
            try writeJSON(trial, to: trialDirectory.appendingPathComponent("capture-state.json"))
        } catch {
            errors.append("capture-state status rewrite: \(error.localizedDescription)")
        }
        do {
            try writeSummaries(manifest.trials,
                               to: root.appendingPathComponent("trials.csv"))
        } catch {
            errors.append("trials.csv status rewrite: \(error.localizedDescription)")
        }
        return ExportResult(errors: errors)
    }

    static func writeManifest(_ manifest: IREValidationManifest, root: URL) throws {
        try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
    }

    private static func appendFrames(_ measurements: [IREFrameMeasurement],
                                     config: IREValidationCaptureConfig,
                                     to url: URL) throws {
        let header = [
            "trial_id", "subject", "stage", "quality_requested", "quality_actual",
            "quality_label", "quality_advertised_options",
            "nobe_reference_ire", "nobe_signal_range", "nobe_reference_confirmed_at",
            "frame_index", "received_at", "received_unix_seconds", "jpeg_bytes", "jpeg_sha256",
            "native_width", "native_height", "source_color_space",
            "patch_index", "patch_name", "sample_count", "zero_count", "clipped_count",
            "production_nonzero_samples", "production_ire",
            "mean_r_ire", "mean_g_ire", "mean_b_ire", "mean_luma_ire",
            "median_luma_ire", "p05_luma_ire", "p95_luma_ire",
        ].joined(separator: ",")
        var rows = [String]()
        rows.reserveCapacity(measurements.count)
        for row in measurements {
            let fields: [String] = [
                csv(config.trialID),
                csv(config.subject.rawValue),
                csv(config.stage.rawValue),
                String(config.camera.qualityRequestedValue),
                String(config.camera.qualityValue),
                csv(config.camera.qualityLabel),
                csv(config.camera.qualityOptions.map { "\($0.label)=\($0.value)" }.joined(separator: "|")),
                number(config.nobeReferenceIRE),
                csv(config.nobeSignalRange.rawValue),
                csv(iso(config.nobeReferenceConfirmedAt)),
                String(row.frameIndex),
                csv(iso(row.receivedAt)),
                number(row.receivedAt.timeIntervalSince1970),
                String(row.jpegBytes),
                row.jpegSHA256,
                String(row.nativeWidth),
                String(row.nativeHeight),
                csv(row.sourceColorSpace),
                row.patchIndex.map(String.init) ?? "",
                csv(row.patchName),
                String(row.sampleCount),
                String(row.zeroCount),
                String(row.clippedCount),
                String(row.productionSampleCount),
                optionalNumber(row.productionIRE),
                number(row.meanRedIRE),
                number(row.meanGreenIRE),
                number(row.meanBlueIRE),
                number(row.meanLumaIRE),
                number(row.medianLumaIRE),
                number(row.p05LumaIRE),
                number(row.p95LumaIRE),
            ]
            rows.append(fields.joined(separator: ","))
        }
        try appendCSV(header: header, rows: rows, to: url)
    }

    private static func writeSummaries(_ trials: [IREValidationManifestTrial],
                                       to url: URL) throws {
        let header = [
            "trial_id", "status", "subject", "stage", "quality_requested",
            "quality_start_actual", "quality_end_actual", "quality_advertised_options",
            "requested_frames", "captured_frames", "patch_index", "patch_name",
            "measured_frames", "pixel_samples", "mean_ire", "median_ire", "sd_ire",
            "mad_ire", "p05_ire", "p95_ire", "one_second_blocks",
            "block_mean_sd_ire", "nobe_reference_ire", "nobe_signal_range",
            "nobe_reference_confirmed_at", "bias_ire",
            "log3g10_stop_error", "production_measured_frames",
            "production_mean_ire", "production_median_ire", "production_sd_ire",
            "production_bias_ire", "production_log3g10_stop_error", "operator_note",
        ].joined(separator: ",")
        var rows = [String]()
        rows.reserveCapacity(trials.reduce(0) { $0 + $1.summaries.count })
        for trial in trials {
            for summary in trial.summaries {
                let fields: [String] = [
                    csv(trial.config.trialID),
                    csv(trial.status),
                    csv(trial.config.subject.rawValue),
                    csv(trial.config.stage.rawValue),
                    String(trial.config.camera.qualityRequestedValue),
                    String(trial.config.camera.qualityValue),
                    trial.endQualityValue.map(String.init) ?? "",
                    csv(trial.config.camera.qualityOptions.map { "\($0.label)=\($0.value)" }.joined(separator: "|")),
                    String(trial.config.requestedFrames),
                    String(trial.capturedFrames),
                    summary.patchIndex.map(String.init) ?? "",
                    csv(summary.patchName),
                    String(summary.measuredFrames),
                    String(summary.totalPixelSamples),
                    number(summary.meanIRE),
                    number(summary.medianIRE),
                    number(summary.standardDeviationIRE),
                    number(summary.madIRE),
                    number(summary.p05IRE),
                    number(summary.p95IRE),
                    String(summary.oneSecondBlockCount),
                    number(summary.oneSecondBlockMeanSDIRE),
                    optionalNumber(summary.nobeReferenceIRE),
                    csv(trial.config.nobeSignalRange.rawValue),
                    csv(iso(trial.config.nobeReferenceConfirmedAt)),
                    optionalNumber(summary.biasIRE),
                    optionalNumber(summary.log3G10StopError),
                    String(summary.productionMeasuredFrames),
                    optionalNumber(summary.productionMeanIRE),
                    optionalNumber(summary.productionMedianIRE),
                    optionalNumber(summary.productionStandardDeviationIRE),
                    optionalNumber(summary.productionBiasIRE),
                    optionalNumber(summary.productionLog3G10StopError),
                    csv(trial.config.operatorNote),
                ]
                rows.append(fields.joined(separator: ","))
            }
        }
        let body = rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
        try (header + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func appendCSV(header: String, rows: [String], to url: URL) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard !rows.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = (rows.joined(separator: "\n") + "\n").data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func optionalNumber(_ value: Double?) -> String {
        value.map(number) ?? ""
    }
}
