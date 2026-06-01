import Foundation
import Photos
import Vision
import UIKit

// MARK: - WhatsApp App Selection

enum WhatsAppApp: String, CaseIterable, Codable {
    case whatsApp         = "WhatsApp"
    case whatsAppBusiness = "WhatsApp Business"
    case both             = "Both"

    var urlScheme: String {
        switch self {
        case .whatsApp:         return "whatsapp://"
        case .whatsAppBusiness: return "whatsappbusiness://"
        case .both:             return "whatsapp://"
        }
    }

    var albumKeyword: String? {
        switch self {
        case .whatsApp:         return "WhatsApp"
        case .whatsAppBusiness: return "WhatsApp Business"
        case .both:             return nil   // nil = match any whatsapp album
        }
    }

    var icon: String {
        switch self {
        case .whatsApp:         return "message.fill"
        case .whatsAppBusiness: return "briefcase.fill"
        case .both:             return "bubble.left.and.bubble.right.fill"
        }
    }
}

// MARK: - WhatsApp Analyzer

actor WhatsAppAnalyzer {

    // MARK: - App Detection

    @MainActor
    static func installedApps() -> [WhatsAppApp] {
        var installed: [WhatsAppApp] = []
        if let url = URL(string: "whatsapp://"), UIApplication.shared.canOpenURL(url) {
            installed.append(.whatsApp)
        }
        if let url = URL(string: "whatsappbusiness://"), UIApplication.shared.canOpenURL(url) {
            installed.append(.whatsAppBusiness)
        }
        return installed
    }

    @MainActor
    static func isInstalled(_ app: WhatsAppApp) -> Bool {
        guard let url = URL(string: app.urlScheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    @MainActor
    static func open(_ app: WhatsAppApp) {
        let scheme = app == .whatsAppBusiness ? "whatsappbusiness://" : "whatsapp://"
        guard let url = URL(string: scheme),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - Album Discovery (filtered by selected app)

    func albums(for app: WhatsAppApp) -> [PHAssetCollection] {
        var result: [PHAssetCollection] = []
        let options = PHFetchOptions()

        if let keyword = app.albumKeyword {
            // Match exact app — WhatsApp Business album contains "Business",
            // regular WhatsApp album is just "WhatsApp" (does NOT contain "Business")
            if app == .whatsApp {
                options.predicate = NSPredicate(
                    format: "title CONTAINS[c] %@ AND NOT title CONTAINS[c] %@",
                    "whatsapp", "business"
                )
            } else {
                options.predicate = NSPredicate(format: "title CONTAINS[c] %@", keyword)
            }
        } else {
            // Both — match any whatsapp album
            options.predicate = NSPredicate(format: "title CONTAINS[c] %@", "whatsapp")
        }

        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            .enumerateObjects { collection, _, _ in result.append(collection) }
        return result
    }

    func allAssets(for app: WhatsAppApp) -> [PHAsset] {
        let albumList = albums(for: app)
        var seen = Set<String>()
        var assets: [PHAsset] = []
        for album in albumList {
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                guard !seen.contains(asset.localIdentifier) else { return }
                seen.insert(asset.localIdentifier)
                assets.append(asset)
            }
        }
        return assets
    }

    func storageMB(for app: WhatsAppApp) -> Double {
        allAssets(for: app).reduce(0.0) { acc, a in
            let bytes = PHAssetResource.assetResources(for: a)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }

    // MARK: - Status Saves (text-heavy + portrait aspect = story saves)

    func statusSaves(from assets: [PHAsset]) async -> [PHAsset] {
        var result: [PHAsset] = []
        await withTaskGroup(of: (PHAsset, Bool).self) { group in
            for asset in assets where asset.mediaType == .image {
                group.addTask { (asset, await self.looksLikeStatus(asset: asset)) }
            }
            for await (asset, isStatus) in group {
                if isStatus { result.append(asset) }
            }
        }
        return result
    }

    private func looksLikeStatus(asset: PHAsset) async -> Bool {
        let ratio = Double(asset.pixelHeight) / Double(max(1, asset.pixelWidth))
        guard ratio > 1.6 else { return false }
        return await detectHighTextDensity(asset: asset)
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
                guard !resumed else { return }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                guard !cancelled, let cgImage = image?.cgImage else {
                    resumed = true; continuation.resume(returning: false); return
                }
                resumed = true
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                continuation.resume(returning: (request.results?.count ?? 0) > 4)
            }
        }
    }

    // MARK: - Forwarded Duplicate Detection

    func forwardedDuplicateGroups(from assets: [PHAsset]) async -> [[PHAsset]] {
        var hashMap: [String: [PHAsset]] = [:]
        await withTaskGroup(of: (PHAsset, String?).self) { group in
            for asset in assets {
                group.addTask { (asset, await self.quickHash(asset: asset)) }
            }
            for await (asset, hash) in group {
                guard let hash else { continue }
                hashMap[hash, default: []].append(asset)
            }
        }
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
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard !resumed else { return }
                resumed = true
                guard let data else { continuation.resume(returning: nil); return }
                let sample = data.prefix(65536)
                var hash: UInt64 = 5381
                for byte in sample { hash = hash &* 31 &+ UInt64(byte) }
                hash = hash &* 31 &+ UInt64(data.count)
                continuation.resume(returning: String(hash))
            }
        }
    }
}
