import Foundation
import Photos
import Vision
import AVFoundation
import UIKit

// MARK: - Video Analyzer

actor VideoAnalyzer {

    private let frameCount = 6
    private let similarityThreshold: Float = 0.45
    private let accidentalDurationThreshold: Double = 3.0

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
        let isScreenRecording = Self.isScreenRecording(asset: asset)
        let resources = PHAssetResource.assetResources(for: asset)
        let fileSize = resources.first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0

        var fp = VideoFingerprint(
            assetID: asset.localIdentifier,
            durationSeconds: duration,
            resolution: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
            fileSize: fileSize,
            isAccidental: isAccidental,
            isScreenRecording: isScreenRecording
        )

        let frames = await sampleFrames(from: asset, count: frameCount)
        for frame in frames {
            guard let cg = frame.cgImage else { continue }
            fp.frameHashes.append(perceptualHash(cgImage: cg))
            if let print = featurePrint(cgImage: cg) {
                fp.framePrints.append(print)
            }
        }
        return fp
    }

    // MARK: - Similarity

    func similarity(a: VideoFingerprint, b: VideoFingerprint) -> Float {
        guard !a.framePrints.isEmpty && !b.framePrints.isEmpty else { return 0 }
        let durationRatio = min(a.durationSeconds, b.durationSeconds) /
                            max(a.durationSeconds, b.durationSeconds)
        guard durationRatio > 0.7 else { return 0 }

        var totalSim: Float = 0
        let count = min(a.framePrints.count, b.framePrints.count)
        for i in 0..<count {
            var dist: Float = 0
            try? a.framePrints[i].computeDistance(&dist, to: b.framePrints[i])
            totalSim += max(0, 1 - dist)
        }
        return count > 0 ? totalSim / Float(count) : 0
    }

    // MARK: - Batch

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
        assets.filter { $0.mediaType == .video && Self.isScreenRecording(asset: $0) }
    }

    // Screen recordings are saved by ReplayKit with filenames like "RPReplay_Final...mp4"
    private static func isScreenRecording(asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { resource in
            let name = resource.originalFilename.lowercased()
            return name.hasPrefix("rpreplay_") || name.contains("screen recording")
        }
    }

    // MARK: - Clustering

    private func clusterByVisualSimilarity(fingerprints: [VideoFingerprint],
                                            allAssets: [PHAsset]) -> [[PHAsset]] {
        let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })
        var visited = Set<String>()
        var clusters: [[PHAsset]] = []

        for i in 0..<fingerprints.count {
            let fp = fingerprints[i]
            guard !visited.contains(fp.assetID) else { continue }

            var cluster = [fp]
            visited.insert(fp.assetID)

            for j in (i + 1)..<fingerprints.count {
                let other = fingerprints[j]
                guard !visited.contains(other.assetID) else { continue }
                if similarity(a: fp, b: other) >= (1 - similarityThreshold) {
                    cluster.append(other)
                    visited.insert(other.assetID)
                }
            }

            if cluster.count > 1 {
                let phAssets = cluster.compactMap { assetMap[$0.assetID] }
                clusters.append(phAssets)
            }
        }
        return clusters
    }

    // MARK: - Frame Sampling (fixed: single continuation resume)

    private func sampleFrames(from asset: PHAsset, count: Int) async -> [UIImage] {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let avAsset else {
                    continuation.resume(returning: [])
                    return
                }

                // requestAVAsset callback is synchronous — use sync duration property
                let duration = CMTimeGetSeconds(avAsset.duration)
                let generator = AVAssetImageGenerator(asset: avAsset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 256, height: 256)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)

                var times: [NSValue] = []
                let safeCount = max(1, count)
                for i in 0..<safeCount {
                    let t = safeCount == 1 ? duration / 2
                                           : duration * Double(i) / Double(safeCount - 1)
                    times.append(NSValue(time: CMTimeMakeWithSeconds(max(0, t), preferredTimescale: 600)))
                }

                // Collect all frames synchronously then resume once
                var frames: [UIImage] = []
                var remaining = times.count

                for time in times {
                    var actualTime = CMTime.zero
                    if let cg = try? generator.copyCGImage(at: time.timeValue, actualTime: &actualTime) {
                        frames.append(UIImage(cgImage: cg))
                    }
                    remaining -= 1
                    if remaining == 0 {
                        continuation.resume(returning: frames)
                    }
                }

                // Safety: if times was empty
                if times.isEmpty {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Hashing

    private func perceptualHash(cgImage: CGImage) -> String {
        guard let ctx = CGContext(
            data: nil, width: 9, height: 8,
            bitsPerComponent: 8, bytesPerRow: 9,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return "" }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        guard let data = ctx.data else { return "" }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 72)

        var hash = ""
        for y in 0..<8 {
            for x in 0..<8 {
                hash += pixels[y * 9 + x] < pixels[y * 9 + x + 1] ? "1" : "0"
            }
        }
        return hash
    }

    private func featurePrint(cgImage: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        return req.results?.first as? VNFeaturePrintObservation
    }
}
