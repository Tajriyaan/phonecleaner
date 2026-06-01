import Foundation
import Photos
import CryptoKit

// MARK: - Hash Analyzer
// Computes SHA256 of raw image data for exact duplicate detection.
// Also builds a lightweight EXIF fingerprint (date + GPS) for cross-source matching.

actor HashAnalyzer {

    private let imageManager = PHImageManager.default()

    // MARK: - SHA256

    func sha256(for asset: PHAsset) async -> String? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .original

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data else { continuation.resume(returning: nil); return }
                let hash = SHA256.hash(data: data)
                continuation.resume(returning: hash.compactMap { String(format: "%02x", $0) }.joined())
            }
        }
    }

    // MARK: - EXIF Fingerprint
    // Same GPS coordinate (within 5m) + same capture second = almost certainly same shot saved from different source.

    func exifFingerprint(for asset: PHAsset) -> String {
        var parts: [String] = []

        if let date = asset.creationDate {
            parts.append(String(Int(date.timeIntervalSince1970)))
        }
        if let loc = asset.location?.coordinate {
            let lat = String(format: "%.4f", loc.latitude)
            let lon = String(format: "%.4f", loc.longitude)
            parts.append("\(lat),\(lon)")
        }
        parts.append("\(asset.pixelWidth)x\(asset.pixelHeight)")
        return parts.joined(separator: "|")
    }

    // MARK: - Batch Hash

    func batchHash(assets: [PHAsset], progress: @escaping (Int) -> Void) async -> [String: [PHAsset]] {
        var hashMap: [String: [PHAsset]] = [:]
        var exifMap: [String: [PHAsset]] = [:]
        var count = 0

        await withTaskGroup(of: (PHAsset, String?, String).self) { group in
            for asset in assets {
                group.addTask { [weak self] in
                    guard let self else { return (asset, nil, "") }
                    let hash = await self.sha256(for: asset)
                    let exif = await self.exifFingerprint(for: asset)
                    return (asset, hash, exif)
                }
            }
            for await (asset, hash, exif) in group {
                count += 1
                progress(count)

                if let hash {
                    hashMap[hash, default: []].append(asset)
                }
                if !exif.isEmpty {
                    exifMap[exif, default: []].append(asset)
                }
            }
        }

        // Merge: exif matches that aren't already in hash groups
        for (_, group) in exifMap where group.count > 1 {
            let ids = Set(group.map(\.localIdentifier))
            let alreadyCovered = hashMap.values.contains { Set($0.map(\.localIdentifier)).isSuperset(of: ids) }
            if !alreadyCovered {
                let syntheticKey = "exif_\(group.map(\.localIdentifier).sorted().joined())"
                hashMap[syntheticKey] = group
            }
        }

        return hashMap.filter { $0.value.count > 1 }
    }
}
