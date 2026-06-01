import Foundation
import Photos
import UIKit
import Accelerate

// MARK: - Quality Analyzer
// Computes sharpness, exposure, and noise scores from pixel data.
// Uses Accelerate for fast histogram and convolution operations.

actor QualityAnalyzer {

    private let imageManager = PHImageManager.default()
    private let sampleSize = CGSize(width: 256, height: 256)

    func score(asset: PHAsset, visionResult: VisionAnalyzer.VisionResult) async -> QualityScore {
        guard let image = await loadSample(asset: asset),
              let cgImage = image.cgImage else {
            return QualityScore(sharpness: 0, exposure: 0, aesthetics: visionResult.aestheticsScore,
                                faceQuality: visionResult.bestFaceQuality,
                                noiseLevel: 0, hasBlur: true, isJunkShot: false,
                                isUtility: visionResult.isUtility)
        }

        let sharpness = computeSharpness(cgImage)
        let (exposure, noise) = computeExposureAndNoise(cgImage)
        let hasBlur = sharpness < 0.08

        let isJunkShot = visionResult.isBodyPartShot
                      || visionResult.isAccidentalShot
                      || (sharpness < 0.05 && visionResult.faceCount == 0)

        return QualityScore(
            sharpness: sharpness,
            exposure: exposure,
            aesthetics: visionResult.aestheticsScore,
            faceQuality: visionResult.bestFaceQuality,
            noiseLevel: noise,
            hasBlur: hasBlur,
            isJunkShot: isJunkShot,
            isUtility: visionResult.isUtility
        )
    }

    // MARK: - Sharpness (Laplacian variance via vDSP)

    private func computeSharpness(_ cgImage: CGImage) -> Float {
        guard let pixels = grayPixels(cgImage) else { return 0 }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 2 && h > 2 else { return 0 }

        // Laplacian kernel: [0,1,0 / 1,-4,1 / 0,1,0]
        var output = [Float](repeating: 0, count: pixels.count)
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]

        var src = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: pixels),
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: w * MemoryLayout<Float>.stride
        )
        output.withUnsafeMutableBufferPointer { ptr in
            var dst = vImage_Buffer(
                data: ptr.baseAddress,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: w * MemoryLayout<Float>.stride
            )
            var k = kernel
            vImageConvolve_PlanarF(&src, &dst, nil, 0, 0, &k, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
        }

        // Variance of Laplacian response
        var mean: Float = 0
        var stddev: Float = 0
        vDSP_normalize(output, 1, nil, 1, &mean, &stddev, vDSP_Length(output.count))
        return min(1.0, stddev * stddev / 0.1)
    }

    // MARK: - Exposure + Noise

    private func computeExposureAndNoise(_ cgImage: CGImage) -> (exposure: Float, noise: Float) {
        guard let pixels = grayPixels(cgImage) else { return (0.5, 0) }

        // Histogram
        var histogram = [vImagePixelCount](repeating: 0, count: 256)
        var src = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: pixels),
            height: vImagePixelCount(cgImage.height),
            width: vImagePixelCount(cgImage.width),
            rowBytes: cgImage.width * MemoryLayout<Float>.stride
        )

        // Convert Float to UInt8 for histogram
        var uint8Pixels = pixels.map { UInt8(max(0, min(255, $0 * 255))) }
        uint8Pixels.withUnsafeMutableBufferPointer { ptr in
            var buf = vImage_Buffer(data: ptr.baseAddress,
                                    height: vImagePixelCount(cgImage.height),
                                    width: vImagePixelCount(cgImage.width),
                                    rowBytes: cgImage.width)
            vImageHistogramCalculation_Planar8(&buf, &histogram, vImage_Flags(kvImageNoFlags))
        }

        let totalPixels = Float(cgImage.width * cgImage.height)
        let darkFraction  = Float(histogram[0..<30].reduce(0, +)) / totalPixels
        let brightFraction = Float(histogram[230...].reduce(0, +)) / totalPixels

        // Good exposure: minimal clipping in shadows or highlights
        let exposureScore = 1.0 - min(1.0, (darkFraction * 2 + brightFraction * 2))

        // Noise: high-frequency energy in uniform (low-variance) regions
        let noiseScore: Float = 0  // simplified — full noise model requires patch analysis

        return (max(0, exposureScore), noiseScore)
    }

    // MARK: - Pixel Helpers

    private func grayPixels(_ cgImage: CGImage) -> [Float]? {
        let w = cgImage.width
        let h = cgImage.height
        var floatPixels = [Float](repeating: 0, count: w * h)

        guard let ctx = CGContext(
            data: &floatPixels,
            width: w, height: h,
            bitsPerComponent: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return floatPixels
    }

    private func loadSample(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false   // quality analysis from local data only

            PHImageManager.default().requestImage(
                for: asset, targetSize: sampleSize,
                contentMode: .aspectFit, options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.resume(returning: image) }
            }
        }
    }
}
