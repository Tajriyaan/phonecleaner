import Foundation
import Photos
import Vision
import UIKit

// MARK: - Scan Engine

@MainActor
final class ScanEngine: ObservableObject {

    @Published var scanState = ScanState()
    @Published var result: ScanResult?
    @Published var isScanning = false

    private let hashAnalyzer    = HashAnalyzer()
    private let visionAnalyzer  = VisionAnalyzer()
    private let qualityAnalyzer = QualityAnalyzer()
    private let videoAnalyzer   = VideoAnalyzer()
    private let clusterer       = DuplicateClusterer()
    private let junkGrouper     = JunkGrouper()

    private var scanTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Init: load cached result immediately

    init() {
        if let cached = ScanPersistence.shared.load() {
            result = cached
        }
    }

    // MARK: - Control

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        // Request background execution time so scan survives app switching
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DeepClean Scan") {
            // Expiry handler — save whatever we have so far
            self.scanTask?.cancel()
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
        scanTask = Task { @MainActor in
            await self.performScan()
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanState.phase = .idle
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Main Pipeline

    private func performScan() async {
        var scanResult = ScanResult()
        let start = Date()

        do {
            // 1. Permissions
            scanState.update(phase: .requestingAccess)
            try await requestPhotoAccess()

            // 2. Load library
            scanState.update(phase: .loadingLibrary)
            let allPHAssets = loadAllAssets()
            let albumMap    = buildAlbumMap()
            let whatsAppIDs = whatsAppAssetIDs()
            scanResult.totalAssetsScanned = allPHAssets.count

            let assets: [MediaAsset] = allPHAssets.map { ph in
                let ma = MediaAsset(phAsset: ph)
                ma.sourceAlbums = albumMap[ph.localIdentifier] ?? []
                ma.isWhatsApp   = whatsAppIDs.contains(ph.localIdentifier)
                return ma
            }

            // 3. Hash (exact duplicates)
            scanState.update(phase: .hashingAssets, processed: 0, total: assets.count)
            let hashGroups = await hashAnalyzer.batchHash(
                assets: allPHAssets,
                progress: { [weak self] n in
                    Task { @MainActor [weak self] in
                        self?.scanState.update(phase: .hashingAssets,
                                               processed: n,
                                               total: allPHAssets.count)
                    }
                }
            )
            guard !Task.isCancelled else { return }

            // 4 + 5. Vision analysis + quality scoring — batched to prevent OOM crash.
            // Running all photos concurrently exhausts RAM on large libraries.
            // Process in batches of 8: each batch loads thumbnails, runs Vision,
            // scores quality, then releases memory before the next batch.
            scanState.update(phase: .visionAnalysis, processed: 0, total: assets.count)
            var visionResults: [String: VisionAnalyzer.VisionResult] = [:]
            let batchSize = 8
            var processed = 0

            for batchStart in stride(from: 0, to: assets.count, by: batchSize) {
                guard !Task.isCancelled else { return }
                let batch = Array(assets[batchStart..<min(batchStart + batchSize, assets.count)])

                // Vision pass for this batch
                await withTaskGroup(of: (String, VisionAnalyzer.VisionResult).self) { group in
                    for asset in batch {
                        group.addTask {
                            let vr = await self.visionAnalyzer.analyse(asset: asset.phAsset)
                            return (asset.id, vr)
                        }
                    }
                    for await (id, vr) in group {
                        visionResults[id] = vr
                        processed += 1
                        let p = processed, t = assets.count
                        await MainActor.run { self.scanState.update(phase: .visionAnalysis, processed: p, total: t) }
                    }
                }

                // Apply vision + quality score immediately for this batch, then release
                for asset in batch {
                    if let vr = visionResults[asset.id] {
                        asset.featurePrint    = vr.featurePrint
                        asset.classifications = vr.classifications
                        asset.detectedText    = vr.hasText
                        asset.faceCount       = vr.faceCount
                        asset.qualityScore    = await qualityAnalyzer.score(
                            asset: asset.phAsset, visionResult: vr)
                    }
                }
                // Release batch thumbnails from memory
                for asset in batch { visionResults.removeValue(forKey: asset.id) }
            }
            // 6. Video analysis
            let videoAssets = allPHAssets.filter { $0.mediaType == .video }
            if !videoAssets.isEmpty {
                scanState.update(phase: .videoAnalysis, processed: 0, total: videoAssets.count)
                let videoGroups = await buildVideoGroups(videoAssets: videoAssets)
                scanResult.groups.append(contentsOf: videoGroups)
            }
            guard !Task.isCancelled else { return }

            // 7. Photo clustering (duplicates + similar)
            scanState.update(phase: .clustering)
            let photoAssets = assets.filter { $0.phAsset.mediaType == .image }
            let duplicateGroups = clusterer.cluster(assets: photoAssets, hashGroups: hashGroups)
            scanResult.groups.append(contentsOf: duplicateGroups)

            // 8. Junk detection
            scanState.update(phase: .junkDetection)
            let junkGroups = junkGrouper.group(assets: photoAssets)
            scanResult.groups.append(contentsOf: junkGroups)

            // 9. iCloud / WhatsApp stats
            scanState.update(phase: .icloudCheck)
            scanResult.iCloudOnlyCount = assets.filter(\.isCloudOnly).count
            scanResult.whatsAppCount   = assets.filter(\.isWhatsApp).count

            // 10. Finalise
            scanState.update(phase: .finalising)
            scanResult.estimatedSavingsBytes = computeSavings(groups: scanResult.groups)
            scanResult.scanDuration = Date().timeIntervalSince(start)

            scanState.phase = .complete
            result = scanResult
            isScanning = false
            // Persist so next launch loads instantly without rescanning
            ScanPersistence.shared.save(scanResult)

        } catch {
            scanState.phase = .failed
            scanState.error = error
            isScanning = false
        }
    }

    // MARK: - Video Groups

    private func buildVideoGroups(videoAssets: [PHAsset]) async -> [MediaGroup] {
        var groups: [MediaGroup] = []

        let accidental = await videoAnalyzer.accidentalClips(assets: videoAssets)
        if !accidental.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.accidentalShot),
                assets: accidental.map { MediaAsset(phAsset: $0) },
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(accidental)
            ))
        }

        let screenRecs = await videoAnalyzer.screenRecordings(assets: videoAssets)
        if !screenRecs.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.screenRecording),
                assets: screenRecs.map { MediaAsset(phAsset: $0) },
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(screenRecs)
            ))
        }

        let similarClusters = await videoAnalyzer.groupDuplicateVideos(assets: videoAssets)
        for cluster in similarClusters {
            groups.append(MediaGroup(
                groupType: .duplicates(.nearDuplicate),
                assets: cluster.map { MediaAsset(phAsset: $0) },
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(cluster)
            ))
        }
        return groups
    }

    // MARK: - Photo Library (synchronous helpers — called before async work)

    private func requestPhotoAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.photoAccessDenied
        }
    }

    private func loadAllAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets    = true
        options.includeAllBurstAssets  = true
        options.sortDescriptors        = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func buildAlbumMap() -> [String: [String]] {
        var map: [String: [String]] = [:]
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { collection, _, _ in
            let name = collection.localizedTitle ?? "Unknown"
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                map[asset.localIdentifier, default: []].append(name)
            }
        }
        return map
    }

    private func whatsAppAssetIDs() -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title CONTAINS[c] %@", "whatsapp")
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        var ids = Set<String>()
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
        }
        return ids
    }

    // MARK: - Helpers

    private func computeSavings(groups: [MediaGroup]) -> Int64 {
        Int64(groups.reduce(0.0) { $0 + $1.estimatedSizeMB } * 1_048_576)
    }

    private func sizeMB(_ assets: [PHAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let bytes = PHAssetResource.assetResources(for: a)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }

    // MARK: - Delete

    func deleteSelected(from group: MediaGroup) async throws {
        let toDelete = group.assetsToDelete.map(\.phAsset) as NSArray
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete)
        }
    }

    func deleteAllSelected() async throws {
        guard let result else { return }
        let toDelete = result.selectedForDeletion.map(\.phAsset) as NSArray
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete)
        }
    }
}

// MARK: - Errors

enum ScanError: LocalizedError {
    case photoAccessDenied
    var errorDescription: String? {
        "Photo library access is required to scan for duplicates."
    }
}
