import Foundation
import Photos
import Vision
import UIKit

// MARK: - Vision Analyzer
// Only uses Vision APIs confirmed available in iOS 26:
//   VNGenerateImageFeaturePrintRequest  (iOS 13+)
//   VNDetectFaceRectanglesRequest       (iOS 11+)
//   VNDetectFaceLandmarksRequest        (iOS 11+)
//   VNRecognizeTextRequest              (iOS 13+)
// Removed: VNClassifyImageRequest (removed iOS 26), VNDetectTextRectanglesRequest (removed iOS 26)

actor VisionAnalyzer {

    private let imageManager = PHImageManager.default()
    private let analysisSize = CGSize(width: 512, height: 512)

    // MARK: - Vision Result

    struct VisionResult {
        var featurePrint: VNFeaturePrintObservation?
        var aestheticsScore: Float = 0
        var isUtility: Bool = false     // detected as screenshot via high text density
        var classifications: [String] = []
        var hasText: Bool = false
        var faceCount: Int = 0
        var bestFaceQuality: Float = 0
        var isBodyPartShot: Bool = false
        var isAccidentalShot: Bool = false
    }

    // MARK: - Full Analysis

    func analyse(asset: PHAsset) async -> VisionResult {
        guard let image = await loadThumbnail(asset: asset),
              let cgImage = image.cgImage else { return VisionResult() }
        return runVisionRequests(on: cgImage, asset: asset)
    }

    // MARK: - Vision Pipeline (iOS 26 compatible)

    private func runVisionRequests(on cgImage: CGImage, asset: PHAsset) -> VisionResult {
        var result = VisionResult()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        // Feature print for similarity matching (always available)
        let fpRequest = VNGenerateImageFeaturePrintRequest()

        // Face detection (always available)
        let faceRequest = VNDetectFaceRectanglesRequest()

        // Text recognition — replaces removed VNDetectTextRectanglesRequest
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false

        try? handler.perform([fpRequest, faceRequest, textRequest])

        // Feature print
        result.featurePrint = fpRequest.results?.first as? VNFeaturePrintObservation

        // Text: high text density = likely screenshot or meme
        let textCount = textRequest.results?.count ?? 0
        result.hasText = textCount > 3

        // Utility (screenshot): high text + portrait/landscape screenshot aspect ratio
        let ratio = Double(asset.pixelWidth) / Double(max(1, asset.pixelHeight))
        let isScreenAspect = (ratio > 0.45 && ratio < 0.48) || (ratio > 2.1 && ratio < 2.2)
        result.isUtility = result.hasText && isScreenAspect

        // Junk shot: no faces, no text, very small dimensions = likely accidental
        result.isAccidentalShot = result.faceCount == 0
                                && !result.hasText
                                && asset.pixelWidth < 400
                                && asset.pixelHeight < 400

        // Faces
        if let faces = faceRequest.results {
            result.faceCount = faces.count
            if !faces.isEmpty {
                result.bestFaceQuality = assessFaceQuality(faces: faces, in: cgImage)
            }
        }

        return result
    }

    // MARK: - Face Quality

    private func assessFaceQuality(faces: [VNFaceObservation], in cgImage: CGImage) -> Float {
        guard let largest = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return 0 }

        let landmarkReq = VNDetectFaceLandmarksRequest()
        landmarkReq.inputFaceObservations = [largest]
        let landmarkHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? landmarkHandler.perform([landmarkReq])

        guard let lmObs = landmarkReq.results?.first as? VNFaceObservation,
              let landmarks = lmObs.landmarks else { return 0.5 }

        var eyeScore: Float = 0.5
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            eyeScore = min(1.0, (eyeOpenness(leftEye) + eyeOpenness(rightEye)) / 0.4)
        }

        let bb = largest.boundingBox
        let faceRect = CGRect(
            x: bb.minX * CGFloat(cgImage.width),
            y: (1 - bb.maxY) * CGFloat(cgImage.height),
            width: bb.width * CGFloat(cgImage.width),
            height: bb.height * CGFloat(cgImage.height)
        )
        let sharpness = cgImage.cropping(to: faceRect).map { laplacianSharpness(of: $0) } ?? 0.5
        return eyeScore * 0.4 + sharpness * 0.6
    }

    private func eyeOpenness(_ landmark: VNFaceLandmarkRegion2D) -> Float {
        let points = landmark.normalizedPoints
        guard points.count >= 6 else { return 0.2 }
        let topY    = (points[1].y + points[2].y + points[3].y) / 3
        let bottomY = (points[4].y + points[5].y) / 2
        return Float(abs(topY - bottomY))
    }

    // MARK: - Feature Print Distance

    func distance(from a: VNFeaturePrintObservation, to b: VNFeaturePrintObservation) -> Float {
        var dist: Float = 0
        try? a.computeDistance(&dist, to: b)
        return dist
    }

    // MARK: - Laplacian Sharpness

    func laplacianSharpness(of cgImage: CGImage) -> Float {
        guard let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let ptr       = CFDataGetBytePtr(cfData) else { return 0 }

        let width         = cgImage.width
        let height        = cgImage.height
        let bytesPerRow   = cgImage.bytesPerRow
        let bytesPerPixel = bytesPerRow / max(1, width)
        guard bytesPerPixel >= 1 && width > 2 && height > 2 else { return 0 }

        var sum: Double = 0, sumSq: Double = 0, count: Double = 0

        for y in stride(from: 1, to: height - 1, by: 4) {
            for x in stride(from: 1, to: width - 1, by: 4) {
                let ch  = min(1, bytesPerPixel - 1)
                let idx = y * bytesPerRow + x * bytesPerPixel
                let lum   = Double(ptr[idx + ch])
                let above = Double(ptr[(y-1) * bytesPerRow + x * bytesPerPixel + ch])
                let below = Double(ptr[(y+1) * bytesPerRow + x * bytesPerPixel + ch])
                let left  = Double(ptr[y * bytesPerRow + (x-1) * bytesPerPixel + ch])
                let right = Double(ptr[y * bytesPerRow + (x+1) * bytesPerPixel + ch])
                let lap = abs(4*lum - above - below - left - right)
                sum += lap; sumSq += lap*lap; count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return Float(min(1.0, ((sumSq/count) - mean*mean) / 2000.0))
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true   // allow iCloud thumbnail download
            options.deliveryMode = .fastFormat       // fastest available — degraded is fine for Vision
            options.resizeMode = .fast

            var resumed = false
            imageManager.requestImage(
                for: asset, targetSize: analysisSize,
                contentMode: .aspectFit, options: options
            ) { image, info in
                guard !resumed else { return }
                // Always resume on FIRST callback — never leave iCloud photos hanging.
                // Degraded thumbnails are acceptable for Vision feature prints.
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if !isCancelled {
                    resumed = true
                    continuation.resume(returning: image)
                } else if !resumed {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
