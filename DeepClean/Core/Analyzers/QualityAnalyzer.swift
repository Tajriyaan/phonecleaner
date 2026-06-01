import Foundation
import Photos
import UIKit
import Accelerate

// MARK: - Quality Analyzer
// Scores sharpness, exposure, and noise for a photo asset.
// Uses simple loop-based Laplacian (no unsafe pointer arithmetic).

actor QualityAnalyzer {

    private let sampleSize = CGSize(width: 256, height: 256)

    func score(asset: PHAsset, visionResult: VisionAnalyzer.VisionResult) async -> QualityScore {
        guard let image = await loadSample(asset: asset),
              let cgImage = image.cgImage else {
            return QualityScore(
                sharpness: 0, exposure: 0,
                aesthetics: visionResult.aestheticsScore,
                faceQuality: visionResult.bestFaceQuality,
                noiseLevel: 0, hasBlur: true,
                isJunkShot: false,
                isUtility: visionResult.isUtility
            )
        }

        let sharpness = computeSharpness(cgImage)
        let exposure  = computeExposure(cgImage)
        let hasBlur   = sharpness < 0.08

        let isJunkShot = visionResult.isBodyPartShot
                      || visionResult.isAccidentalShot
                      || (sharpness < 0.05 && visionResult.faceCount == 0)

        return QualityScore(
            sharpness: sharpness,
            exposure: exposure,
            aesthetics: visionResult.aestheticsScore,
            faceQuality: visionResult.bestFaceQuality,
            noiseLevel: 0,
            hasBlur: hasBlur,
            isJunkShot: isJunkShot,
            isUtility: visionResult.isUtility
        )
    }

    // MARK: - Sharpness via Laplacian variance (pure Swift, no unsafe pointers)

    private func computeSharpness(_ cgImage: CGImage) -> Float {
        guard let pixels = grayFloatPixels(cgImage) else { return 0 }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 2 && h > 2 else { return 0 }

        var sum: Float = 0
        var sumSq: Float = 0
        var count: Float = 0

        // Sample every 3rd pixel for speed on 256x256 images
        for y in stride(from: 1, to: h - 1, by: 3) {
            for x in stride(from: 1, to: w - 1, by: 3) {
                let c = pixels[y * w + x]
                let t = pixels[(y - 1) * w + x]
                let b = pixels[(y + 1) * w + x]
                let l = pixels[y * w + (x - 1)]
                let r = pixels[y * w + (x + 1)]
                let lap = abs(4 * c - t - b - l - r)
                sum   += lap
                sumSq += lap * lap
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean     = sum / count
        let variance = (sumSq / count) - (mean * mean)
        return min(1.0, variance / 80.0)   // empirically normalised
    }

    // MARK: - Exposure (histogram via vDSP)

    private func computeExposure(_ cgImage: CGImage) -> Float {
        guard let pixels = grayFloatPixels(cgImage) else { return 0.5 }
        let total = Float(pixels.count)
        guard total > 0 else { return 0.5 }

        // Fraction of pixels that are very dark or very bright
        var darkCount: Float  = 0
        var brightCount: Float = 0
        for p in pixels {
            if p < 0.12 { darkCount  += 1 }
            if p > 0.90 { brightCount += 1 }
        }
        let darkFrac   = darkCount / total
        let brightFrac = brightCount / total
        return max(0, 1.0 - min(1.0, darkFrac * 2 + brightFrac * 2))
    }

    // MARK: - Gray pixel extraction (32-bit float, values 0-1)

    private func grayFloatPixels(_ cgImage: CGImage) -> [Float]? {
        let w = cgImage.width
        let h = cgImage.height
        var pixels = [Float](repeating: 0, count: w * h)

        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 32,
            bytesPerRow: w * MemoryLayout<Float>.stride,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    // MARK: - Image loading

    private func loadSample(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: sampleSize,
                contentMode: .aspectFit, options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded && !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
