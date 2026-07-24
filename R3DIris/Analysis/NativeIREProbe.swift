//  NativeIREProbe.swift — R3DIris / Analysis
//  Native-resolution hero-IRE measurement for an ROI detected at 480 px.
//
//  Detection and all of its gates intentionally stay on PixelBuffer's small
//  working image. Once an ROI exists, this helper maps that geometry back to
//  the decoded MJPEG frame and rasterizes only the hero-probe bounding box at
//  1:1 resolution. A full 1920×1080 float buffer would cost tens of megabytes
//  per analyzed frame; the center probe is normally only a few thousand bytes.

import CoreGraphics
import Foundation

struct NativeIREMeasurement: Sendable, Equatable {
    let ire: Double
    /// Non-zero pixels considered before percentile trimming.
    let sampleCount: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let probeRadiusPixels: Double
}

enum NativeIREProbe {
    /// Same center-disk geometry as SphereDetector.heroIRE.
    static let heroProbeRadiusFraction = 0.24
    static let requiredSourceWidth = 1920
    static let requiredSourceHeight = 1080

    /// Reproject a detection-buffer ROI to the source frame. The ROI remains
    /// expressed in the small detection buffer everywhere else; this function
    /// is the only resolution crossing in the production analysis path.
    static func measureHero(
        in image: CGImage,
        detectionROI roi: SphereROI,
        bufferWidth: Int,
        bufferHeight: Int
    ) -> NativeIREMeasurement? {
        guard bufferWidth > 0, bufferHeight > 0 else { return nil }
        return measureHero(
            in: image,
            normalizedCenterX: roi.cx / Double(bufferWidth),
            normalizedCenterY: roi.cy / Double(bufferHeight),
            normalizedRadiusByWidth: roi.r / Double(bufferWidth)
        )
    }

    /// Measure the approved normalized ROI directly from the decoded source
    /// frame. Coordinates follow SphereState: x/width, y/height, r/width.
    static func measureHero(
        in image: CGImage,
        normalizedCenterX: Double,
        normalizedCenterY: Double,
        normalizedRadiusByWidth: Double
    ) -> NativeIREMeasurement? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth == requiredSourceWidth,
              sourceHeight == requiredSourceHeight,
              normalizedCenterX.isFinite, normalizedCenterY.isFinite,
              normalizedRadiusByWidth.isFinite,
              normalizedRadiusByWidth > 0 else { return nil }

        let cx = normalizedCenterX * Double(sourceWidth)
        let cy = normalizedCenterY * Double(sourceHeight)
        let sphereRadius = normalizedRadiusByWidth * Double(sourceWidth)
        let probeRadius = sphereRadius * heroProbeRadiusFraction
        guard cx.isFinite, cy.isFinite, probeRadius.isFinite, probeRadius > 0 else {
            return nil
        }

        // One extra pixel around the disk protects the inclusive edge test
        // from fractional centers without expanding work beyond a tiny crop.
        let x0 = max(0, Int(floor(cx - probeRadius - 1)))
        let y0 = max(0, Int(floor(cy - probeRadius - 1)))
        let x1 = min(sourceWidth - 1, Int(ceil(cx + probeRadius + 1)))
        let y1 = min(sourceHeight - 1, Int(ceil(cy + probeRadius + 1)))
        guard x0 <= x1, y0 <= y1 else { return nil }

        let cropWidth = x1 - x0 + 1
        let cropHeight = y1 - y0 + 1
        var raw = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let rasterized: Bool = raw.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: cropWidth,
                height: cropHeight,
                bitsPerComponent: 8,
                bytesPerRow: cropWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            // Offset the same full-frame draw used by PixelBuffer, but let the
            // crop context clip everything outside the native probe bounds.
            // There is no scaling, so JPEG pixels are measured 1:1.
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(
                    x: -CGFloat(x0),
                    // Bitmap memory rows are top-down relative to the drawing
                    // coordinate system. Account for the shorter crop context
                    // so its row 0 matches full-frame memory row `y0`.
                    y: CGFloat(y0 + cropHeight - sourceHeight),
                    width: CGFloat(sourceWidth),
                    height: CGFloat(sourceHeight)
                )
            )
            return true
        }
        guard rasterized else { return nil }

        let radiusSquared = probeRadius * probeRadius
        var values: [Float] = []
        values.reserveCapacity(Int(.pi * probeRadius * probeRadius) + 4)
        for localY in 0..<cropHeight {
            let dy = Double(localY + y0) - cy
            for localX in 0..<cropWidth {
                let dx = Double(localX + x0) - cx
                guard dx * dx + dy * dy <= radiusSquared else { continue }
                let offset = (localY * cropWidth + localX) * 4
                let red = Float(raw[offset]) / 255.0
                let green = Float(raw[offset + 1]) / 255.0
                let blue = Float(raw[offset + 2]) / 255.0
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                values.append(luma)
            }
        }

        guard let estimate = productionEstimate(fromNormalizedLuma: values) else {
            return nil
        }

        return NativeIREMeasurement(
            ire: estimate.ire,
            sampleCount: estimate.nonzeroSampleCount,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            probeRadiusPixels: probeRadius
        )
    }

    /// Exact estimator used by the live app: discard zero luma, trim the
    /// lowest/highest 5%, then take the upper median and express it as IRE.
    /// Bench validation calls this same function so its "production" column
    /// cannot drift from the operator readout while retaining separate
    /// zero-inclusive diagnostics for range analysis.
    static func productionEstimate(
        fromNormalizedLuma values: [Float]
    ) -> (ire: Double, nonzeroSampleCount: Int)? {
        var usable = values.filter { $0 > 0 }
        guard usable.count >= 4 else { return nil }
        usable.sort()
        let low = Int(Double(usable.count) * 0.05)
        let high = max(low + 1, Int(Double(usable.count) * 0.95))
        let upperBound = min(high, usable.count)
        guard low < upperBound else { return nil }
        let medianIndex = low + (upperBound - low) / 2
        return (Double(usable[medianIndex]) * 100.0, usable.count)
    }
}
