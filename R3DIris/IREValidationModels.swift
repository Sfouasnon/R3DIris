//  IREValidationModels.swift — R3DIris
//  Value types shared by the Bench IRE evidence recorder, analyzer, exporter,
//  and live-view ROI overlay.

import Foundation

enum IREValidationSignalRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case video
    case full

    var id: String { rawValue }
    var label: String { self == .video ? "Video / legal" : "Full / data" }
}

struct IRENormalizedPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

enum IREValidationSubject: String, CaseIterable, Codable, Identifiable, Sendable, Equatable {
    case grayCard
    case graySphere
    case colorChecker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grayCard: return "18% gray card"
        case .graySphere: return "18% gray sphere"
        case .colorChecker: return "Macbeth ColorChecker"
        }
    }

    var pointInstruction: String {
        switch self {
        case .grayCard:
            return "Click two opposite corners of a flat, uniformly lit interior ROI."
        case .graySphere:
            return "Click the sphere center; set the outer-radius slider to the overlay."
        case .colorChecker:
            return "Click chart corners in order: TL → TR → BR → BL."
        }
    }

    var requiredPointCount: Int {
        switch self {
        case .grayCard: return 2
        case .graySphere: return 1
        case .colorChecker: return 4
        }
    }
}

enum IREValidationStage: String, CaseIterable, Codable, Identifiable, Sendable, Equatable {
    case signalBlack
    case gray18
    case ire50
    case nearWhite
    case minusOneStop
    case minusHalfStop
    case plusHalfStop
    case plusOneStop
    case colorChecker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .signalBlack: return "Signal black"
        case .gray18: return "18% gray"
        case .ire50: return "50 IRE"
        case .nearWhite: return "Near-white"
        case .minusOneStop: return "−1 stop"
        case .minusHalfStop: return "−0.5 stop"
        case .plusHalfStop: return "+0.5 stop"
        case .plusOneStop: return "+1 stop"
        case .colorChecker: return "ColorChecker"
        }
    }
}

struct IREValidationSelection: Codable, Sendable {
    var points: [IRENormalizedPoint] = []
    /// Sphere outline radius as a fraction of image width. Measurement uses
    /// the production center probe (0.24 × this outer radius).
    var sphereOuterRadius: Double = 0.075
    /// Macbeth patch index whose simultaneous Nobe value is the absolute
    /// reference. All 24 patches are still measured and exported.
    var colorCheckerReferencePatch: Int = 21

    func isComplete(for subject: IREValidationSubject) -> Bool {
        points.count == subject.requiredPointCount
    }
}

struct IREValidationCameraSnapshot: Codable, Sendable {
    var ip: String
    var name: String
    var serial: String
    var firmware: String
    var clipName: String
    var qualityRequestedValue: Int
    var qualityRequestSource: String
    var qualityValue: Int
    var qualityLabel: String
    var qualityOptions: [LivestreamQualityOption]
    var mirrorSourceValue: Int?
    var mirrorSourceLabel: String
    var livestreamRectRaw: String
    var monitorTransform: String
    var monitorTransformParameter: String
    var monitorTransformValue: Int?
}

struct IREValidationCaptureConfig: Codable, Sendable {
    var trialID: String
    var subject: IREValidationSubject
    var stage: IREValidationStage
    var requestedFrames: Int
    var nobeReferenceIRE: Double
    var nobeSignalRange: IREValidationSignalRange
    /// Operator confirmation time recorded by the Capture action. Nobe has no
    /// numeric API here, so this timestamps the manual simultaneous reference.
    var nobeReferenceConfirmedAt: Date
    var operatorNote: String
    var selection: IREValidationSelection
    var camera: IREValidationCameraSnapshot
    var streamWidth: Int
    var streamHeight: Int
    var startedAt: Date
    var appVersion: String
}

struct IREValidationRawFrame: Sendable {
    var index: Int
    var receivedAt: Date
    var jpeg: Data
}

struct IREFrameMeasurement: Codable, Sendable {
    var frameIndex: Int
    var receivedAt: Date
    var jpegBytes: Int
    var jpegSHA256: String
    var nativeWidth: Int
    var nativeHeight: Int
    var sourceColorSpace: String
    var patchIndex: Int?
    var patchName: String
    var sampleCount: Int
    var zeroCount: Int
    var clippedCount: Int
    /// The exact live-app estimator: non-zero luma, 5–95% trim, upper median.
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

struct IRETrialSummary: Codable, Sendable {
    var patchIndex: Int?
    var patchName: String
    var measuredFrames: Int
    var totalPixelSamples: Int
    var meanIRE: Double
    var medianIRE: Double
    var standardDeviationIRE: Double
    var madIRE: Double
    var p05IRE: Double
    var p95IRE: Double
    var oneSecondBlockCount: Int
    var oneSecondBlockMeanSDIRE: Double
    var nobeReferenceIRE: Double?
    var biasIRE: Double?
    var log3G10StopError: Double?
    var productionMeasuredFrames: Int
    var productionMeanIRE: Double?
    var productionMedianIRE: Double?
    var productionStandardDeviationIRE: Double?
    var productionBiasIRE: Double?
    var productionLog3G10StopError: Double?
}

struct IREValidationAnalysisResult: Sendable {
    var measurements: [IREFrameMeasurement]
    var summaries: [IRETrialSummary]
    var decodeFailures: Int
    var analysisErrors: [String]
}

struct IREValidationManifestTrial: Codable, Sendable {
    var config: IREValidationCaptureConfig
    var completedAt: Date
    var capturedFrames: Int
    var status: String
    var endQualityValue: Int?
    var endQualityLabel: String
    var endMirrorSourceValue: Int?
    var endMonitorTransform: String
    var endMonitorTransformParameter: String
    var endMonitorTransformValue: Int?
    var endLivestreamRectRaw: String
    var decodeFailures: Int
    var rawDirectory: String
    var errors: [String]
    var summaries: [IRETrialSummary]
}

struct IREValidationManifest: Codable, Sendable {
    var schemaVersion = 1
    var createdAt: Date
    var updatedAt: Date
    var status: String
    var measurementDescription =
        "Untouched port-9090 JPEGs decoded by ImageIO, rasterized into an sRGB 8-bit working context, then measured at native frame dimensions. Frame received_at is the URLSession delegate-chunk arrival time captured before the MainActor hop; multiple JPEGs completed by one chunk share that timestamp. Diagnostic values retain zero/clipped samples; production values use the live app's exact non-zero, 5–95% trimmed upper-median estimator. Values are MJPEG IRE estimates (BT.709 code-value luma × 100), not an SDI replacement."
    var referenceDescription =
        "Nobe OmniScope values are operator-entered 10-bit SDI waveform references, with the selected Video/Full range and Capture-time operator confirmation timestamp recorded per trial. ColorChecker patch values are diagnostic; the selected neutral patch alone carries the Nobe reference."
    var trials: [IREValidationManifestTrial]
}

enum IREColorChecker {
    static let columns = 6
    static let rows = 4

    static let patchNames = [
        "Dark Skin", "Light Skin", "Blue Sky", "Foliage", "Blue Flower", "Bluish Green",
        "Orange", "Purplish Blue", "Moderate Red", "Purple", "Yellow Green", "Orange Yellow",
        "Blue", "Green", "Red", "Yellow", "Magenta", "Cyan",
        "White 9.5", "Neutral 8", "Neutral 6.5", "Neutral 5", "Neutral 3.5", "Black 2",
    ]

    static let neutralPatchIndices = Array(18...23)

    static func name(for index: Int) -> String {
        patchNames.indices.contains(index) ? patchNames[index] : "Patch \(index + 1)"
    }
}

/// Projective transform from a unit 6×4 chart plane into normalized image
/// coordinates. Four operator clicks solve the transform, so a perspective-
/// skewed chart does not collapse into a simple axis-aligned grid.
struct IREChartHomography: Sendable {
    private let h: [Double]

    init?(corners: [IRENormalizedPoint]) {
        guard corners.count == 4 else { return nil }
        let source = [
            IRENormalizedPoint(x: 0, y: 0),
            IRENormalizedPoint(x: 1, y: 0),
            IRENormalizedPoint(x: 1, y: 1),
            IRENormalizedPoint(x: 0, y: 1),
        ]

        var matrix = [[Double]]()
        for i in 0..<4 {
            let u = source[i].x, v = source[i].y
            let x = corners[i].x, y = corners[i].y
            matrix.append([u, v, 1, 0, 0, 0, -u * x, -v * x, x])
            matrix.append([0, 0, 0, u, v, 1, -u * y, -v * y, y])
        }
        guard let solved = Self.solve(matrix) else { return nil }
        h = solved
    }

    func project(u: Double, v: Double) -> IRENormalizedPoint? {
        let denominator = h[6] * u + h[7] * v + 1
        guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
        let x = (h[0] * u + h[1] * v + h[2]) / denominator
        let y = (h[3] * u + h[4] * v + h[5]) / denominator
        guard x.isFinite, y.isFinite else { return nil }
        return IRENormalizedPoint(x: x, y: y)
    }

    func patchQuad(index: Int, insetFraction: Double = 0.16) -> [IRENormalizedPoint]? {
        guard (0..<IREColorChecker.patchNames.count).contains(index) else { return nil }
        let column = index % IREColorChecker.columns
        let row = index / IREColorChecker.columns
        let cellWidth = 1.0 / Double(IREColorChecker.columns)
        let cellHeight = 1.0 / Double(IREColorChecker.rows)
        let insetX = cellWidth * insetFraction
        let insetY = cellHeight * insetFraction
        let left = Double(column) * cellWidth + insetX
        let right = Double(column + 1) * cellWidth - insetX
        let top = Double(row) * cellHeight + insetY
        let bottom = Double(row + 1) * cellHeight - insetY
        let unitCorners = [(left, top), (right, top), (right, bottom), (left, bottom)]
        let projected = unitCorners.compactMap { project(u: $0.0, v: $0.1) }
        return projected.count == 4 ? projected : nil
    }

    private static func solve(_ augmented: [[Double]]) -> [Double]? {
        var a = augmented
        let n = 8
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }
            if pivot != column { a.swapAt(pivot, column) }

            let divisor = a[column][column]
            for value in column...n { a[column][value] /= divisor }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                if abs(factor) <= 1e-15 { continue }
                for value in column...n {
                    a[row][value] -= factor * a[column][value]
                }
            }
        }
        return (0..<n).map { a[$0][n] }
    }
}
