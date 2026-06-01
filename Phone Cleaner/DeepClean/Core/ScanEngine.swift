import Foundation
import Photos
import Vision

// MARK: - Scan Engine
// Central actor that orchestrates the full deep-clean scan.
// Publishes progress through ScanState and returns a final ScanResult.

@MainActor
final class ScanEngine: ObservableObject {

    @Published var scanState = ScanState()
    @Published var result: ScanResult?
    @Published var isScanning = false

    private let hashAnalyzer   = HashAnalyzer()
    private let visionAnalyzer = VisionAnalyzer()
    private let qualityAnalyzer = QualityAnalyzer()
    private let videoAnalyzer  = VideoAnalyzer()
    private let clusterer      = DuplicateClusterer()
    private let junkGrouper    = JunkGrouper()

    private var scanTask: Task<Void, Never>?

    // MARK: - Start Scan

    func startScan() {
        guard !isScanning else { return }

        scanTask = Task {
            await performScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanState.phase = .idle
    }

    // MARK: - Main Scan Pipeline

    private func performScan() async {
        isScanning = true
        var scanResult = ScanResult()
        let start = Date()

        do {
            // Step 1: Permissions
            scanState.update(phase: .requestingAccess)
            try await requestPhotoAccess()

            // Step 2: Load library
            scanState.update(phase: .loadingLibrary)
            let allPHAssets = await loadAllAssets()
            let albumMap    = await buildAlbumMap()
            let whatsAppIDs = await whatsAppAssetIDs()

            scanResult.totalAssetsScanned = allPHAssets.count

            // Wrap into MediaAsset
            let assets: [MediaAsset] = allPHAssets.map { ph in
                let ma = MediaAsset(phAsset: ph)
                ma.sourceAlbums = albumMap[ph.localIdentifier] ?? []
                ma.isWhatsApp   = whatsAppIDs.contains(ph.localIdentifier)
                return ma
            }

            // Step 3: Hash analysis (exact duplicates)
            scanState.update(phase: .hashingAssets, total: assets.count)
            let hashGroups = await hashAnalyzer.batchHash(
                assets: allPHAssets,
                progress: { [weak self] n in
                    Task { @MainActor in
                        self?.scanState.update(phase: .hashingAssets, processed: n, total: allPHAssets.count)
                    }
                }
            )

            guard !Task.isCancelled else { return }

            // Step 4: Vision analysis (feature prints + aesthetics + classification)
            scanState.update(phase: .visionAnalysis, total: assets.count)
            await analyseWithVision(assets: assets)

            guard !Task.isCancelled else { return }

            // Step 5: Quality scoring
            scanState.update(phase: .qualityScoring, total: assets.count)
            await scoreQuality(assets: assets)

            guard !Task.isCancelled else { return }

            // Step 6: Video analysis
            let videoAssets = assets.filter { $0.phAsset.mediaType == .video }
            if !videoAssets.isEmpty {
                scanState.update(phase: .videoAnalysis, total: videoAssets.count)
                let videoGroups = await buildVideoGroups(videoAssets: videoAssets.map(\.phAsset))
                scanResult.groups.append(contentsOf: videoGroups)
            }

            guard !Task.isCancelled else { return }

            // Step 7: Clustering
            scanState.update(phase: .clustering, total: assets.count)
            let photoAssets = assets.filter { $0.phAsset.mediaType == .image }
            let duplicateGroups = clusterer.cluster(assets: photoAssets, hashGroups: hashGroups)
            scanResult.groups.append(contentsOf: duplicateGroups)

            guard !Task.isCancelled else { return }

            // Step 8: Junk detection
            scanState.update(phase: .junkDetection)
            let junkGroups = junkGrouper.group(assets: photoAssets)
            scanResult.groups.append(contentsOf: junkGroups)

            // Step 9: iCloud stats
            scanState.update(phase: .icloudCheck)
            scanResult.iCloudOnlyCount = assets.filter(\.isCloudOnly).count
            scanResult.whatsAppCount   = assets.filter(\.isWhatsApp).count

            // Step 10: Finalise
            scanState.update(phase: .finalising)
            scanResult.estimatedSavingsBytes = computeSavings(groups: scanResult.groups)
            scanResult.scanDuration = Date().timeIntervalSince(start)

            // Done
            scanState.phase = .complete
            result = scanResult
            isScanning = false

        } catch {
            scanState.phase = .failed
            scanState.error = error
            isScanning = false
        }
    }

    // MARK: - Vision Pass (concurrent, batched)

    private func analyseWithVision(assets: [MediaAsset]) async {
        let batchSize = 20
        var processed = 0

        await withTaskGroup(of: (MediaAsset, VisionAnalyzer.VisionResult).self) { group in
            for asset in assets {
                group.addTask { [va = self.visionAnalyzer] in
                    let result = await va.analyse(asset: asset.phAsset)
                    return (asset, result)
                }
            }
            for await (asset, vr) in group {
                asset.featurePrint    = vr.featurePrint
                asset.classifications = vr.classifications
                asset.detectedText    = vr.hasText
                asset.faceCount       = vr.faceCount
                processed += 1
                if processed % batchSize == 0 {
                    scanState.update(phase: .visionAnalysis, processed: processed, total: assets.count)
                }
            }
        }
    }

    // MARK: - Quality Pass

    private func scoreQuality(assets: [MediaAsset]) async {
        var processed = 0

        await withTaskGroup(of: (MediaAsset, QualityScore).self) { group in
            for asset in assets {
                group.addTask { [qa = self.qualityAnalyzer, va = self.visionAnalyzer] in
                    // Build a stub VisionResult to pass aesthetics score already computed
                    let vr = VisionAnalyzer.VisionResult()
                    let score = await qa.score(asset: asset.phAsset, visionResult: vr)
                    return (asset, score)
                }
            }
            for await (asset, score) in group {
                asset.qualityScore = score
                processed += 1
                if processed % 50 == 0 {
                    scanState.update(phase: .qualityScoring, processed: processed, total: assets.count)
                }
            }
        }
    }

    // MARK: - Video Groups

    private func buildVideoGroups(videoAssets: [PHAsset]) async -> [MediaGroup] {
        var groups: [MediaGroup] = []

        let accidental = await videoAnalyzer.accidentalClips(assets: videoAssets)
        if !accidental.isEmpty {
            let mediaAssets = accidental.map { MediaAsset(phAsset: $0) }
            groups.append(MediaGroup(
                groupType: .junk(.accidentalShot),
                assets: mediaAssets,
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(accidental)
            ))
        }

        let screenRecs = await videoAnalyzer.screenRecordings(assets: videoAssets)
        if !screenRecs.isEmpty {
            let mediaAssets = screenRecs.map { MediaAsset(phAsset: $0) }
            groups.append(MediaGroup(
                groupType: .junk(.screenRecording),
                assets: mediaAssets,
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(screenRecs)
            ))
        }

        let similarClusters = await videoAnalyzer.groupDuplicateVideos(assets: videoAssets)
        for cluster in similarClusters {
            let mediaAssets = cluster.map { MediaAsset(phAsset: $0) }
            groups.append(MediaGroup(
                groupType: .duplicates(.nearDuplicate),
                assets: mediaAssets,
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(cluster)
            ))
        }

        return groups
    }

    // MARK: - Photo Library Helpers

    private func requestPhotoAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.photoAccessDenied
        }
    }

    private func loadAllAssets() async -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func buildAlbumMap() async -> [String: [String]] {
        var map: [String: [String]] = [:]
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { collection, _, _ in
            let name = collection.localizedTitle ?? "Unknown"
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                map[asset.localIdentifier, default: []].append(name)
            }
        }
        return map
    }

    private func whatsAppAssetIDs() async -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title CONTAINS[c] %@", "whatsapp")
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)

        var ids = Set<String>()
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }

    private func computeSavings(groups: [MediaGroup]) -> Int64 {
        Int64(groups.reduce(0.0) { $0 + $1.estimatedSizeMB } * 1_048_576)
    }

    private func sizeMB(_ assets: [PHAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let res = PHAssetResource.assetResources(for: a)
            let bytes = res.first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }

    // MARK: - Delete

    func deleteSelected(from group: MediaGroup) async throws {
        let toDelete = group.assetsToDelete.map(\.phAsset)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
        }
    }

    func deleteAllSelected() async throws {
        guard let result else { return }
        let allToDelete = result.selectedForDeletion.map(\.phAsset)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(allToDelete as NSFastEnumeration)
        }
    }
}

// MARK: - Errors

enum ScanError: LocalizedError {
    case photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .photoAccessDenied: return "Photo library access is required to scan for duplicates."
        }
    }
}
