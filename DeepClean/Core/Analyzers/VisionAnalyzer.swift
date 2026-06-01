import Foundation
import Photos
import Vision
import UIKit

// MARK: - Vision Analyzer

actor VisionAnalyzer {

    private let imageManager = PHImageManager.default()
    private let analysisSize = CGSize(width: 512, height: 512)

    // MARK: - Vision Result

    struct VisionResult {
        var featurePrint: VNFeaturePrintObservation?
        var aestheticsScore: Float = 0
        var isUtility: Bool = false
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
        return runVisionRequests(on: cgImage)
    }

    // MARK: - Vision Pipeline

    private func runVisionRequests(on cgImage: CGImage) -> VisionResult {
        var result = VisionResult()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let fpRequest       = VNGenerateImageFeaturePrintRequest()
        let classifyRequest = VNClassifyImageRequest()
        let textRequest     = VNDetectTextRectanglesRequest()
        let faceRequest     = VNDetectFaceRectanglesRequest()

        var requests: [VNRequest] = [fpRequest, classifyRequest, textRequest, faceRequest]

        var aestheticsRequest: VNRequest?
        if #available(iOS 17.0, *) {
            let ar = VNGenerateImageAestheticsScoresRequest()
            aestheticsRequest = ar
            requests.append(ar)
        }

        try? handler.perform(requests)

        // Feature print
        result.featurePrint = fpRequest.results?.first as? VNFeaturePrintObservation

        // Aesthetics
        if #available(iOS 17.0, *),
           let obs = aestheticsRequest?.results?.first as? VNImageAestheticsScoresObservation {
            result.aestheticsScore = obs.overallScore
            result.isUtility = obs.isUtility
        }

        // Classifications
        if let obs = classifyRequest.results as? [VNClassificationObservation] {
            result.classifications = obs.filter { $0.confidence > 0.3 }.map(\.identifier)

            let bodyPartLabels: Set<String> = ["beard", "face", "hand", "ear", "eye", "neck",
                                                "arm", "shoulder", "hair", "leg", "foot",
                                                "finger", "nose", "lip", "teeth"]
            let accidentalLabels: Set<String> = ["floor", "ceiling", "wall", "carpet", "fabric",
                                                  "textile", "wood", "concrete", "pavement"]
            let topThree = Set(obs.prefix(3).map(\.identifier))

            result.isBodyPartShot  = !topThree.isDisjoint(with: bodyPartLabels)
                                   && (obs.first?.confidence ?? 0) > 0.7
            result.isAccidentalShot = !topThree.isDisjoint(with: accidentalLabels)
                                   && (obs.first?.confidence ?? 0) > 0.65
        }

        // Text detection
        result.hasText = ((textRequest.results as? [VNTextObservation])?.count ?? 0) > 3

        // Faces
        if let faces = faceRequest.results as? [VNFaceObservation] {
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
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([landmarkReq])

        guard let lmObs = landmarkReq.results?.first as? VNFaceObservation,
              let landmarks = lmObs.landmarks else { return 0.5 }

        var eyeScore: Float = 0.5
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            let lOpen = eyeOpenness(leftEye)
            let rOpen = eyeOpenness(rightEye)
            eyeScore = min(1.0, (lOpen + rOpen) / 0.4)
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
        return abs(topY - bottomY)
    }

    // MARK: - Feature Print Distance

    func distance(from a: VNFeaturePrintObservation, to b: VNFeaturePrintObservation) -> Float {
        var dist: Float = 0
        try? a.computeDistance(&dist, to: b)
        return dist
    }

    // MARK: - Laplacian Sharpness (used externally by DuplicateClusterer ranker)

    func laplacianSharpness(of cgImage: CGImage) -> Float {
        guard let provider = cgImage.dataProvider,
              let cfData   = provider.data,
              let ptr       = CFDataGetBytePtr(cfData) else { return 0 }

        let width        = cgImage.width
        let height       = cgImage.height
        let bytesPerRow  = cgImage.bytesPerRow
        let bytesPerPixel = bytesPerRow / max(1, width)

        guard bytesPerPixel >= 1 && width > 2 && height > 2 else { return 0 }

        var sum: Double = 0
        var sumSq: Double = 0
        var count: Double = 0

        for y in stride(from: 1, to: height - 1, by: 4) {
            for x in stride(from: 1, to: width - 1, by: 4) {
                let idx = y * bytesPerRow + x * bytesPerPixel
                let safeChannel = min(1, bytesPerPixel - 1)   // green or first channel

                let lum    = Double(ptr[idx + safeChannel])
                let above  = Double(ptr[(y - 1) * bytesPerRow + x * bytesPerPixel + safeChannel])
                let below  = Double(ptr[(y + 1) * bytesPerRow + x * bytesPerPixel + safeChannel])
                let left   = Double(ptr[y * bytesPerRow + (x - 1) * bytesPerPixel + safeChannel])
                let right  = Double(ptr[y * bytesPerRow + (x + 1) * bytesPerPixel + safeChannel])
                let lap = abs(4 * lum - above - below - left - right)

                sum   += lap
                sumSq += lap * lap
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = (sumSq / count) - (mean * mean)
        return Float(min(1.0, variance / 2000.0))
    }

    // MARK: - Thumbnail Loading (safe: always resumes exactly once)

    private func loadThumbnail(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous  = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode   = .opportunistic
            options.resizeMode     = .fast

            var resumed = false
            imageManager.requestImage(
                for: asset, targetSize: analysisSize,
                contentMode: .aspectFit, options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded && !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
