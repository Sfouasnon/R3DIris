//  Log3G10.swift — R3DIris / Analysis
//  Exact RED Log3G10 transfer-function math used by R3DMatch v5.
//
//  Source: RED white paper 915-0187 Rev-C, as cited by
//  R3DMatch_v5/src/r3dmatch3/brdf_verify.py. These functions are deliberately
//  pure so the simulator and app loop can exercise identical math.

import Foundation

enum Log3G10 {
    static let a = 0.224282
    static let b = 155.975327
    static let c = 0.01
    static let g = 15.1927

    /// 18% scene-linear gray's expected Log3G10 code value, expressed as IRE.
    /// Keep the calibrated value intact for matching and round only UI text.
    static let grayAnchorIRE = 33.333291

    /// Scene-linear value to normalized Log3G10 code value.
    static func encode(_ linear: Double) -> Double {
        let shifted = linear + c
        if shifted >= 0 {
            return a * log10(shifted * b + 1.0)
        }
        return g * shifted
    }

    /// Normalized Log3G10 code value to scene-linear light.
    static func linearize(_ encoded: Double) -> Double {
        if encoded >= 0 {
            return (pow(10.0, encoded / a) - 1.0) / b - c
        }
        return encoded / g - c
    }

    /// Exposure correction from a measured Log3G10 hero level to a reference.
    /// Inputs are IRE (0…100), matching SphereDetector.heroIRE. Positive means
    /// the measured camera needs more exposure; negative means it needs less.
    static func stops(between referenceIRE: Double, and measuredIRE: Double) -> Double {
        let referenceLinear = linearize(referenceIRE / 100.0)
        let measuredLinear = linearize(measuredIRE / 100.0)
        guard referenceLinear > 0, measuredLinear > 0 else { return .nan }
        return log2(referenceLinear / measuredLinear)
    }
}
