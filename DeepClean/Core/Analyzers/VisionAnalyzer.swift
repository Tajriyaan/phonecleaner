import Foundation
import Photos
import Vision
import UIKit

// MARK: - Vision Analyzer
// Runs all Vision framework requests for a single asset:
//   - Feature print (similarity embedding)
//   - Image aesthetics score (iOS 17+)
//   - Classification (what's in the photo)
//   - Text detection (screenshot / receipt indicator)
//   - Face detection + quality

actor VisionAnalyzer {

    private let imageManager = PHImageManager.default()

    // Thumbnail size for fast analysis — full-res not needed for embeddings
    private let analysisSize = CGSize(width: 512, height: 512)

    // MARK: - Full Analysis

    struct VisionResult {
        var featurePrint: VNFeaturePrintObservation?
        var aestheticsScore: Float = 0
        var isUtility: Bool = false     // screenshot / document
        var classifications: [String] = []
        var hasText: Bool = false
        var faceCount: Int = 0
        var bestFaceQuality: Float = 0
        var isBodyPartShot: Bool = false
        var isAccidentalShot: Bool = false
    }

    func analyse(asset: PHAsset) async -> VisionResult {
        guard let image = await loadThumbnail(asset: asset) else { return VisionResult() }
        let cgImage = image.cgImage!
        return await runVisionRequests(on: cgImage)
    }

    // MARK: - Core Vision Pipeline

    private func runVisionRequests(on cgImage: CGImage) async -> VisionResult {
        var result = VisionResult()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        // Feature print
        let fpRequest = VNGenerateImageFeaturePrintRequest()

        // Aesthetics (iOS 17+)
        var aestheticsRequest: VNRequest?
        if #available(iOS 17.0, *) {
            aestheticsRequest = VNGenerateImageAestheticsScoresRequest()
        }

        // Classification
        let classifyRequest = VNClassifyImageRequest()

        // Text detection (fast, no recognition needed)
        let textRequest = VNDetectTextRectanglesRequest()
        textRequest.reportCharacterBoxes = false

        // Face detection
        let faceRequest = VNDetectFaceRectanglesRequest()

        var requests: [VNRequest] = [fpRequest, classifyRequest, textRequest, faceRequest]
        if let ar = aestheticsRequest { requests.append(ar) }

        try? handler.perform(requests)

        // --- Feature Print ---
        result.featurePrint = fpRequest.results?.first as? VNFeaturePrintObservation

        // --- Aesthetics ---
        if #available(iOS 17.0, *),
           let obs = aestheticsRequest?.results?.first as? VNImageAestheticsScoresObservation {
            result.aestheticsScore = obs.overallScore
            result.isUtility = obs.isUtility
        }

        // --- Classifications ---
        if let obs = classifyRequest.results as? [VNClassificationObservation] {
            result.classifications = obs
                .filter { $0.confidence > 0.3 }
                .map(\.identifier)

            // Body part shot: dominant classification is a body part, no meaningful subject
            let bodyPartLabels = ["beard", "face", "hand", "ear", "eye", "neck", "arm", "shoulder",
                                  "hair", "leg", "foot", "finger", "nose", "lip", "teeth"]
            let topLabels = Set(obs.prefix(3).map(\.identifier))
            result.isBodyPartShot = !topLabels.isDisjoint(with: bodyPartLabels)
                                 && obs.first.map { $0.confidence > 0.7 } ?? false

            // Accidental shot: dominated by floor/ceiling/wall/pocket textures
            let accidentalLabels = ["floor", "ceiling", "wall", "carpet", "fabric", "textile",
                                    "wood", "concrete", "pavement", "darkness", "blur"]
            result.isAccidentalShot = !topLabels.isDisjoint(with: accidentalLabels)
                                    && (obs.first?.confidence ?? 0) > 0.65
        }

        // --- Text ---
        result.hasText = (textRequest.results as? [VNTextObservation])?.count ?? 0 > 3

        // --- Faces ---
        if let faces = faceRequest.results as? [VNFaceObservation] {
            result.faceCount = faces.count
            if !faces.isEmpty {
                result.bestFaceQuality = assessFaceQuality(faces: faces, in: cgImage)
            }
        }

        return result
    }

    // MARK: - Face Quality
    // Runs landmark detection on the largest face to score sharpness + eye openness.

    private func assessFaceQuality(faces: [VNFaceObservation], in cgImage: CGImage) -> Float {
        guard let largest = faces.max(by: { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }) else { return 0 }

        let landmarkReq = VNDetectFaceLandmarksRequest()
        landmarkReq.inputFaceObservations = [largest]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([landmarkReq])

        guard let landmarkResult = landmarkReq.results?.first as? VNFaceObservation,
              let landmarks = landmarkResult.landmarks else { return 0.5 }

        // Eye openness: approximate ratio of eye height to width
        var eyeScore: Float = 0.5
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            let openness = eyeOpenness(leftEye) + eyeOpenness(rightEye)
            eyeScore = min(1.0, openness / 0.4)
        }

        // Face-region sharpness
        let faceBox = largest.boundingBox
        let faceRect = CGRect(
            x: faceBox.minX * CGFloat(cgImage.width),
            y: (1 - faceBox.maxY) * CGFloat(cgImage.height),
            width: faceBox.width * CGFloat(cgImage.width),
            height: faceBox.height * CGFloat(cgImage.height)
        )
        let sharpness = cgImage.cropping(to: faceRect).map { laplacianSharpness(of: $0) } ?? 0

        return eyeScore * 0.4 + sharpness * 0.6
    }

    private func eyeOpenness(_ landmark: VNFaceLandmarkRegion2D) -> Float {
        let points = landmark.normalizedPoints
        guard points.count >= 6 else { return 0.2 }
        let top = points[1...3].map(\.y).reduce(0, +) / 3
        let bottom = points[4...5].map(\.y).reduce(0, +) / 2
        return abs(top - bottom)
    }

    // MARK: - Feature Print Distance

    func distance(from a: VNFeaturePrintObservation, to b: VNFeaturePrintObservation) -> Float {
        var dist: Float = 0
        try? a.computeDistance(&dist, to: b)
        return dist
    }

    // MARK: - Helpers

    private func loadThumbnail(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true   // allow cloud thumbnail download
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast

            imageManager.requestImage(
                for: asset,
                targetSize: analysisSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded { continuation.resume(returning: image) }
            }
        }
    }

    // Laplacian variance — proxy for sharpness; higher = sharper.
    func laplacianSharpness(of cgImage: CGImage) -> Float {
        guard let pixelData = cgImage.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return 0 }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bitsPerComponent = cgImage.bitsPerComponent
        guard bitsPerComponent == 8 else { return 0 }

        var sum: Double = 0
        var sumSq: Double = 0
        var count: Double = 0

        // Sample every 4th pixel for speed
        for y in stride(from: 1, to: height - 1, by: 4) {
            for x in stride(from: 1, to: width - 1, by: 4) {
                let bytesPerPixel = bytesPerRow / width
                let idx = y * bytesPerRow + x * bytesPerPixel

                // Luminance (grayscale approximation from RGB)
                let r = Double(data[idx])
                let g = Double(data[idx + 1])
                let b = Double(data[idx + 2])
                let lum = 0.299 * r + 0.587 * g + 0.114 * b

                // Laplacian kernel on luminance
                let above = Double(data[(y-1) * bytesPerRow + x * bytesPerPixel + 1])
                let below = Double(data[(y+1) * bytesPerRow + x * bytesPerPixel + 1])
                let left  = Double(data[y * bytesPerRow + (x-1) * bytesPerPixel + 1])
                let right = Double(data[y * bytesPerRow + (x+1) * bytesPerPixel + 1])
                let lap = abs(4 * lum - above - below - left - right)

                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = (sumSq / count) - (mean * mean)
        // Normalize to 0-1 range (typical range 0-2000)
        return Float(min(1.0, variance / 2000.0))
    }
}
