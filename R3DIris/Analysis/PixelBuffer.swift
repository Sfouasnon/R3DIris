//  PixelBuffer.swift — R3DIris / Analysis
//  CGImage → planar float RGB working buffer for sphere detection and
//  measurement. Frames come from the :9090 MJPEG livestream (8-bit,
//  display-referred — handoff §6: match relative levels only, never claim
//  scene-linear accuracy).

import Foundation
import CoreGraphics

/// Sendable wrapper for handing a decoded CGImage to a detached analysis task.
/// CGImage is immutable; the wrapper only exists to satisfy strict concurrency.
struct FrameHandle: @unchecked Sendable {
    let image: CGImage
}

/// Planar float RGB + BT.709 luma in [0, 1], row 0 = top.
struct PixelBuffer: Sendable {
    let width: Int
    let height: Int
    let r: [Float]
    let g: [Float]
    let b: [Float]
    let luma: [Float]

    @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { y * width + x }

    /// Rasterize a CGImage into a working buffer, downscaled so the longest
    /// side is `maxDim` (R3DMatch detects at 1080; the livestream is already
    /// ≤1080-class, and 480 keeps the live loop cheap — the sphere still spans
    /// ≥10 px at the smallest calibrated r/w of 0.018).
    static func from(_ image: CGImage, maxDim: Int = 480) -> PixelBuffer? {
        let scale = min(1.0, Double(maxDim) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))

        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok: Bool = raw.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard ok else { return nil }

        var rr = [Float](repeating: 0, count: w * h)
        var gg = [Float](repeating: 0, count: w * h)
        var bb = [Float](repeating: 0, count: w * h)
        var ll = [Float](repeating: 0, count: w * h)
        // CGContext rows are top-down for images drawn this way on macOS when
        // no flip transform is applied to a bitmap context — but verify with
        // the on-screen overlay: if the sphere circle lands mirrored
        // vertically, flip here. (Bench checklist item; costs one look.)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let i = y * w + x
                let rf = Float(raw[o]) / 255.0
                let gf = Float(raw[o + 1]) / 255.0
                let bf = Float(raw[o + 2]) / 255.0
                rr[i] = rf; gg[i] = gf; bb[i] = bf
                // BT.709 luma — same coefficients as R3DMatch sphere.py _to_gray_arr
                ll[i] = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            }
        }
        return PixelBuffer(width: w, height: h, r: rr, g: gg, b: bb, luma: ll)
    }
}
