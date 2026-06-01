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

    // MARK: - Init: load cached result, skip rescan if library unchanged

    init() {
        if let cached = ScanPersistence.shared.load() {
            result = cached
        }
    }

    /// Returns true if the photo library has changed since the last scan.
    /// Uses PHPhotoLibrary change token — if unchanged, no rescan needed.
    var libraryChangedSinceLastScan: Bool {
        let currentToken = PHPhotoLibrary.shared().currentChangeToken
        let tokenData = try? NSKeyedArchiver.archivedData(
            withRootObject: currentToken, requiringSecureCoding: true)
        let savedData = UserDefaults.standard.data(forKey: "lastScanChangeToken")
        if tokenData == savedData { return false }
        return true
    }

    private func saveChangeToken() {
        let token = PHPhotoLibrary.shared().currentChangeToken
        let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: "lastScanChangeToken")
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
            // ── 1. Permissions ──────────────────────────────────────────────
            scanState.update(phase: .requestingAccess)
            try await requestPhotoAccess()

            // ── 2. Load library ─────────────────────────────────────────────
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

            // ── 3. PHASE 1: Exact duplicates (fast — EXIF + thumbnail hash) ─
            // Runs in seconds. Publishes first results immediately so user
            // can start reviewing while deeper analysis continues.
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

            // Cluster duplicates immediately and publish — user can start deleting now
            let photoAssets = assets.filter { $0.phAsset.mediaType == .image }
            let quickDuplicates = clusterer.cluster(assets: photoAssets, hashGroups: hashGroups)
            scanResult.groups = quickDuplicates
            scanResult.estimatedSavingsBytes = computeSavings(groups: scanResult.groups)
            result = scanResult                          // ← FIRST PUBLISH
            ScanPersistence.shared.save(scanResult)     // ← cache phase 1

            // ── 4. PHASE 2: AI Vision + Quality (batched, memory-safe) ──────
            // Runs in background while user reviews phase 1 results.
            // Publishes updated groups every 50 photos.
            scanState.update(phase: .visionAnalysis, processed: 0, total: assets.count)
            var visionResults: [String: VisionAnalyzer.VisionResult] = [:]
            // 6 concurrent Vision requests — small enough to avoid memory pressure
            // while still being faster than sequential. Each task has an 8s timeout
            // so a stuck asset never blocks the whole scan.
            let batchSize = 6
            var processed = 0

            for batchStart in stride(from: 0, to: assets.count, by: batchSize) {
                guard !Task.isCancelled else { return }
                let batch = Array(assets[batchStart..<min(batchStart + batchSize, assets.count)])

                // Analyse every photo regardless of size
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
                        await MainActor.run {
                            self.scanState.update(phase: .visionAnalysis, processed: p, total: t)
                        }
                    }
                }

                // Apply Vision + quality, release batch memory immediately
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
                for asset in batch { visionResults.removeValue(forKey: asset.id) }

                // Save partial results every 100 photos so user has something
                // to review even if scan stops early (memory pressure / timeout)
                if processed % 100 == 0 {
                    let partial = clusterer.cluster(assets: photoAssets, hashGroups: hashGroups)
                    scanResult.groups = partial
                    scanResult.estimatedSavingsBytes = computeSavings(groups: partial)
                    result = scanResult
                    ScanPersistence.shared.save(scanResult)
                }

                // Yield to system between batches to reduce memory pressure
                await Task.yield()
            }
            guard !Task.isCancelled else { return }

            // ── 5. Final clustering (runs ONCE with full Vision data) ────────
            scanState.update(phase: .clustering)
            let finalDuplicates = clusterer.cluster(assets: photoAssets, hashGroups: hashGroups)

            // ── 6. Junk detection ────────────────────────────────────────────
            scanState.update(phase: .junkDetection)
            let finalJunk = junkGrouper.group(assets: photoAssets)

            // ── 7. Video analysis ────────────────────────────────────────────
            scanState.update(phase: .videoAnalysis, processed: 0, total: 0)
            var videoGroups: [MediaGroup] = []
            let videoAssets = allPHAssets.filter { $0.mediaType == .video }
            if !videoAssets.isEmpty {
                videoGroups = await buildVideoGroups(videoAssets: videoAssets)
            }
            guard !Task.isCancelled else { return }

            // ── 8. iCloud stats ──────────────────────────────────────────────
            scanState.update(phase: .icloudCheck)
            scanResult.iCloudOnlyCount = assets.filter(\.isCloudOnly).count
            scanResult.whatsAppCount   = assets.filter(\.isWhatsApp).count

            // ── 9. Finalise ──────────────────────────────────────────────────
            scanState.update(phase: .finalising)
            scanResult.groups = finalDuplicates + finalJunk + videoGroups
            scanResult.estimatedSavingsBytes = computeSavings(groups: scanResult.groups)
            scanResult.scanDuration = Date().timeIntervalSince(start)

            // ── 10. Smart Categories ─────────────────────────────────────────
            scanState.update(phase: .finalising)
            let faceCounts = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.faceCount) })
            SmartCategorizer.applyAll(
                categories: &CategoryStore.shared.categories,
                to: allPHAssets,
                visionFaceCounts: faceCounts,
                mediaAssets: assets
            )

            scanState.phase = .complete
            result = scanResult
            isScanning = false
            ScanPersistence.shared.save(scanResult)
            saveChangeToken()

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
        let deletedIDs = Set(group.assetsToDelete.map(\.id))
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete)
        }
        removeDeletedAssets(ids: deletedIDs)
    }

    func deleteAllSelected() async throws {
        guard let result else { return }
        let toDelete = result.selectedForDeletion.map(\.phAsset) as NSArray
        let deletedIDs = Set(result.selectedForDeletion.map(\.id))
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete)
        }
        removeDeletedAssets(ids: deletedIDs)
    }

    /// Called after any deletion — removes assets from all groups and categories,
    /// drops empty groups, and republishes result so every screen refreshes instantly.
    func removeDeletedAssets(ids: Set<String>) {
        // Update scan result groups
        if var r = result {
            r.groups = r.groups.compactMap { group in
                let remaining = group.assets.filter { !ids.contains($0.id) }
                guard remaining.count > 0 else { return nil }
                let updated = MediaGroup(
                    groupType: group.groupType,
                    assets: remaining,
                    confidence: group.confidence,
                    estimatedSizeMB: group.estimatedSizeMB * Double(remaining.count) / Double(group.assets.count)
                )
                return updated
            }
            r.estimatedSavingsBytes = computeSavings(groups: r.groups)
            result = r
            ScanPersistence.shared.save(r)
        }
        // Update smart categories
        for i in CategoryStore.shared.categories.indices {
            CategoryStore.shared.categories[i].assetIDs.removeAll { ids.contains($0) }
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
