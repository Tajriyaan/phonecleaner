import Foundation
import Photos
import UIKit

// MARK: - Hash Analyzer
// Fast duplicate detection using metadata + thumbnail fingerprinting.
// NO original image downloads — all data available instantly from Photos metadata.
//
// Strategy:
//   1. EXIF fingerprint: creation date (to second) + GPS (4dp) + pixel dimensions
//      → zero network, instant, catches same photo saved multiple times
//   2. Thumbnail hash: dHash of a 9x8 tiny thumbnail
//      → fast, catches near-exact duplicates even if metadata differs
//   Groups assets that share either key.

actor HashAnalyzer {

    private let imageManager = PHImageManager.default()

    // MARK: - EXIF Fingerprint (metadata only, no image data)

    func exifFingerprint(for asset: PHAsset) -> String {
        var parts: [String] = []
        if let date = asset.creationDate {
            parts.append(String(Int(date.timeIntervalSince1970)))
        }
        if let loc = asset.location?.coordinate {
            parts.append(String(format: "%.4f,%.4f", loc.latitude, loc.longitude))
        }
        parts.append("\(asset.pixelWidth)x\(asset.pixelHeight)")
        if let dur = asset.mediaType == .video ? Optional(asset.duration) : nil {
            parts.append(String(Int(dur)))
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Thumbnail dHash (fast perceptual hash, no network)

    func thumbnailHash(for asset: PHAsset) async -> String {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false   // local only — skip iCloud assets

            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 9, height: 8),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                resumed = true

                guard let cgImage = image?.cgImage,
                      let ctx = CGContext(
                          data: nil, width: 9, height: 8,
                          bitsPerComponent: 8, bytesPerRow: 9,
                          space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.none.rawValue
                      ) else {
                    continuation.resume(returning: "")
                    return
                }
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 9, height: 8))
                guard let data = ctx.data else {
                    continuation.resume(returning: "")
                    return
                }
                let pixels = data.bindMemory(to: UInt8.self, capacity: 72)
                var hash = ""
                for y in 0..<8 {
                    for x in 0..<8 {
                        hash += pixels[y * 9 + x] < pixels[y * 9 + x + 1] ? "1" : "0"
                    }
                }
                continuation.resume(returning: hash)
            }
        }
    }

    // MARK: - Batch Analysis

    struct AssetFingerprints {
        let asset: PHAsset
        let exif: String
        let thumbnailHash: String
    }

    func batchHash(
        assets: [PHAsset],
        progress: @escaping (Int) -> Void
    ) async -> [String: [PHAsset]] {

        var fingerprints: [AssetFingerprints] = []

        // Process in batches of 50 to avoid spawning thousands of tasks
        let batchSize = 50
        var processed = 0

        for batchStart in stride(from: 0, to: assets.count, by: batchSize) {
            let batch = Array(assets[batchStart..<min(batchStart + batchSize, assets.count)])

            let batchResults = await withTaskGroup(
                of: AssetFingerprints.self
            ) { group in
                for asset in batch {
                    group.addTask {
                        let exif  = await self.exifFingerprint(for: asset)
                        let thumb = await self.thumbnailHash(for: asset)
                        return AssetFingerprints(asset: asset, exif: exif, thumbnailHash: thumb)
                    }
                }
                var results: [AssetFingerprints] = []
                for await fp in group { results.append(fp) }
                return results
            }

            fingerprints.append(contentsOf: batchResults)
            processed += batch.count
            progress(processed)
        }

        // Group by EXIF fingerprint (catches identical photos from different sources)
        var exifGroups: [String: [PHAsset]] = [:]
        for fp in fingerprints where !fp.exif.isEmpty {
            exifGroups[fp.exif, default: []].append(fp.asset)
        }

        // Group by thumbnail hash (catches near-identical photos with different metadata)
        var thumbGroups: [String: [PHAsset]] = [:]
        for fp in fingerprints where fp.thumbnailHash.count == 64 {
            thumbGroups[fp.thumbnailHash, default: []].append(fp.asset)
        }

        // Merge: keep only groups with 2+ assets
        var merged: [String: [PHAsset]] = [:]

        for (key, group) in exifGroups where group.count > 1 {
            merged["exif_\(key)"] = group
        }

        // Add thumbnail groups not already covered by EXIF
        let coveredIDs = Set(merged.values.flatMap { $0.map(\.localIdentifier) })
        for (key, group) in thumbGroups where group.count > 1 {
            let newAssets = group.filter { !coveredIDs.contains($0.localIdentifier) }
            if newAssets.count > 1 { merged["thumb_\(key)"] = newAssets }
        }

        return merged
    }
}
