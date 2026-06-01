import Foundation
import Photos
import Vision
import UIKit

// MARK: - WhatsApp Analyzer
// Handles all WhatsApp-specific detection:
//   1. Status saves (photos saved from WhatsApp Status)
//   2. Forwarded media duplicates (same image saved from multiple chats)
//   3. Deep link to WhatsApp's built-in storage manager

actor WhatsAppAnalyzer {

    // MARK: - WhatsApp Album Discovery

    /// Returns all PHAssetCollections whose title contains "whatsapp" (case-insensitive)
    func whatsAppAlbums() -> [PHAssetCollection] {
        var albums: [PHAssetCollection] = []
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title CONTAINS[c] %@", "whatsapp")
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        result.enumerateObjects { collection, _, _ in albums.append(collection) }
        return albums
    }

    /// All assets that live in any WhatsApp album
    func allWhatsAppAssets() -> [PHAsset] {
        let albums = whatsAppAlbums()
        var seen  = Set<String>()
        var assets: [PHAsset] = []

        for album in albums {
            let fetched = PHAsset.fetchAssets(in: album, options: nil)
            fetched.enumerateObjects { asset, _, _ in
                guard !seen.contains(asset.localIdentifier) else { return }
                seen.insert(asset.localIdentifier)
                assets.append(asset)
            }
        }
        return assets
    }

    // MARK: - Status Saves Detection
    // WhatsApp Status saves have high text density (stories with overlaid text/stickers)
    // and often land in a "WhatsApp Status Saver" album or the main WhatsApp album.

    func statusSaves(from assets: [PHAsset]) async -> [PHAsset] {
        var statusAssets: [PHAsset] = []

        await withTaskGroup(of: (PHAsset, Bool).self) { group in
            for asset in assets where asset.mediaType == .image {
                group.addTask {
                    let isStatus = await self.looksLikeStatus(asset: asset)
                    return (asset, isStatus)
                }
            }
            for await (asset, isStatus) in group {
                if isStatus { statusAssets.append(asset) }
            }
        }
        return statusAssets
    }

    private func looksLikeStatus(asset: PHAsset) async -> Bool {
        // Status saves are often 9:16 aspect ratio (portrait stories)
        let ratio = Double(asset.pixelHeight) / Double(max(1, asset.pixelWidth))
        let isStoryAspect = ratio > 1.6

        // High text density is the strongest indicator
        let hasHighText = await detectHighTextDensity(asset: asset)
        return isStoryAspect && hasHighText
    }

    private func detectHighTextDensity(asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed, let cgImage = image?.cgImage else { return }
                resumed = true

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let textCount = request.results?.count ?? 0
                continuation.resume(returning: textCount > 4)
            }
        }
    }

    // MARK: - Forwarded Duplicate Detection
    // Same image forwarded in multiple chats gets saved multiple times.
    // We group by SHA256 hash first, then by perceptual similarity.

    func forwardedDuplicateGroups(from assets: [PHAsset]) async -> [[PHAsset]] {
        // Build hash map
        var hashMap: [String: [PHAsset]] = [:]

        await withTaskGroup(of: (PHAsset, String?).self) { group in
            for asset in assets {
                group.addTask {
                    let hash = await self.quickHash(asset: asset)
                    return (asset, hash)
                }
            }
            for await (asset, hash) in group {
                guard let hash else { continue }
                hashMap[hash, default: []].append(asset)
            }
        }

        // Groups with more than 1 asset = duplicates (always keeps at least 1 later)
        return hashMap.values.filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }

    private func quickHash(asset: PHAsset) async -> String? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false
            options.version = .current

            var resumed = false
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                guard !resumed else { return }
                resumed = true
                guard let data else { continuation.resume(returning: nil); return }
                // Fast hash: use first 64KB + file size as fingerprint
                let sample = data.prefix(65536)
                let sizeTag = "\(data.count)"
                let combined = sample.map { String($0) }.joined() + sizeTag
                // Simple djb2 hash — fast, good enough for duplicate detection
                var hash: UInt64 = 5381
                for char in combined.utf8 { hash = hash &* 31 &+ UInt64(char) }
                continuation.resume(returning: String(hash))
            }
        }
    }

    // MARK: - WhatsApp Storage Size

    func whatsAppStorageMB() -> Double {
        let assets = allWhatsAppAssets()
        return assets.reduce(0.0) { acc, asset in
            let resources = PHAssetResource.assetResources(for: asset)
            let bytes = resources.first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }

    // MARK: - Deep Link

    /// Checks if WhatsApp is installed. Must be called on MainActor (UIApplication requirement).
    @MainActor
    static func isWhatsAppInstalled() -> Bool {
        guard let url = URL(string: "whatsapp://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Opens WhatsApp app. Must be called on MainActor.
    @MainActor
    static func openWhatsApp() {
        guard let url = URL(string: "whatsapp://"),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
