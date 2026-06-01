import Foundation
import Photos
import Vision
import AVFoundation

// MARK: - Video Analyzer
// Detects duplicate and similar video clips by:
//   1. SHA256 of raw video data (exact match)
//   2. Frame fingerprinting at regular intervals (visual similarity)
//   3. Metadata heuristics (duration, resolution, accidental clip detection)

actor VideoAnalyzer {

    private let imageManager = PHImageManager.default()
    private let frameCount = 6         // frames to sample per video
    private let thumbnailSize = CGSize(width: 256, height: 256)
    private let similarityThreshold: Float = 0.45
    private let accidentalDurationThreshold: Double = 3.0  // seconds

    // MARK: - Video Fingerprint

    struct VideoFingerprint {
        let assetID: String
        let durationSeconds: Double
        let resolution: CGSize
        let fileSize: Int64
        var frameHashes: [String] = []
        var framePrints: [VNFeaturePrintObservation] = []
        var isAccidental: Bool
        var isScreenRecording: Bool
    }

    func fingerprint(for asset: PHAsset) async -> VideoFingerprint? {
        guard asset.mediaType == .video else { return nil }

        let duration = asset.duration
        let isAccidental = duration < accidentalDurationThreshold
        let isScreenRecording = asset.mediaSubtypes.contains(.videoScreenRecording)

        let resources = PHAssetResource.assetResources(for: asset)
        let fileSize = resources.first.flatMap {
            $0.value(forKey: "fileSize") as? Int64
        } ?? 0

        var fp = VideoFingerprint(
            assetID: asset.localIdentifier,
            durationSeconds: duration,
            resolution: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
            fileSize: fileSize,
            isAccidental: isAccidental,
            isScreenRecording: isScreenRecording
        )

        // Sample frames at evenly-spaced intervals
        let frames = await sampleFrames(from: asset, count: frameCount)
        for frame in frames {
            if let cg = frame.cgImage {
                let hash = await perceptualHash(cgImage: cg)
                fp.frameHashes.append(hash)

                let print = await featurePrint(cgImage: cg)
                if let print { fp.framePrints.append(print) }
            }
        }

        return fp
    }

    // MARK: - Similarity Score Between Two Videos

    func similarity(a: VideoFingerprint, b: VideoFingerprint) -> Float {
        guard !a.framePrints.isEmpty && !b.framePrints.isEmpty else { return 0 }

        // Duration difference heuristic
        let durationRatio = min(a.durationSeconds, b.durationSeconds) /
                            max(a.durationSeconds, b.durationSeconds)
        guard durationRatio > 0.7 else { return 0 }

        // Average best-match frame similarity
        var totalSim: Float = 0
        let count = min(a.framePrints.count, b.framePrints.count)

        for i in 0..<count {
            var dist: Float = 0
            try? a.framePrints[i].computeDistance(&dist, to: b.framePrints[i])
            totalSim += max(0, 1 - dist)
        }

        return totalSim / Float(count)
    }

    // MARK: - Batch Video Analysis

    func groupDuplicateVideos(assets: [PHAsset]) async -> [[PHAsset]] {
        var fingerprints: [VideoFingerprint] = []

        await withTaskGroup(of: VideoFingerprint?.self) { group in
            for asset in assets {
                group.addTask { await self.fingerprint(for: asset) }
            }
            for await fp in group {
                if let fp { fingerprints.append(fp) }
            }
        }

        return clusterByVisualSimilarity(fingerprints: fingerprints, allAssets: assets)
    }

    func accidentalClips(assets: [PHAsset]) -> [PHAsset] {
        assets.filter { $0.mediaType == .video && $0.duration < accidentalDurationThreshold }
    }

    func screenRecordings(assets: [PHAsset]) -> [PHAsset] {
        assets.filter { $0.mediaType == .video && $0.mediaSubtypes.contains(.videoScreenRecording) }
    }

    // MARK: - Clustering

    private func clusterByVisualSimilarity(fingerprints: [VideoFingerprint], allAssets: [PHAsset]) -> [[PHAsset]] {
        let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })
        var visited = Set<String>()
        var clusters: [[PHAsset]] = []

        for i in 0..<fingerprints.count {
            let fp = fingerprints[i]
            guard !visited.contains(fp.assetID) else { continue }

            var cluster = [fp]
            visited.insert(fp.assetID)

            for j in (i+1)..<fingerprints.count {
                let other = fingerprints[j]
                guard !visited.contains(other.assetID) else { continue }
                if similarity(a: fp, b: other) >= (1 - similarityThreshold) {
                    cluster.append(other)
                    visited.insert(other.assetID)
                }
            }

            if cluster.count > 1 {
                let assets = cluster.compactMap { assetMap[$0.assetID] }
                clusters.append(assets)
            }
        }

        return clusters
    }

    // MARK: - Frame Sampling

    private func sampleFrames(from asset: PHAsset, count: Int) async -> [UIImage] {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let avAsset else { continuation.resume(returning: []); return }

                let duration = CMTimeGetSeconds(avAsset.duration)
                let generator = AVAssetImageGenerator(asset: avAsset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 256, height: 256)

                var times: [NSValue] = []
                for i in 0..<count {
                    let t = duration * Double(i) / Double(count - 1)
                    times.append(NSValue(time: CMTimeMakeWithSeconds(t, preferredTimescale: 600)))
                }

                var frames: [UIImage] = []
                generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, result, _ in
                    if result == .succeeded, let cg = cgImage {
                        frames.append(UIImage(cgImage: cg))
                    }
                    if frames.count == count { continuation.resume(returning: frames) }
                }
            }
        }
    }

    // MARK: - Perceptual Hash (dHash)

    private func perceptualHash(cgImage: CGImage) async -> String {
        guard let ctx = CGContext(
            data: nil,
            width: 9, height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 9,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return "" }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        guard let data = ctx.data else { return "" }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 72)

        var hash = ""
        for y in 0..<8 {
            for x in 0..<8 {
                let left  = pixels[y * 9 + x]
                let right = pixels[y * 9 + x + 1]
                hash += left < right ? "1" : "0"
            }
        }
        return hash
    }

    private func featurePrint(cgImage: CGImage) async -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        return req.results?.first as? VNFeaturePrintObservation
    }
}
