import Foundation
import Photos
import Vision

// MARK: - Scan Engine

@MainActor
final class ScanEngine: ObservableObject {

    @Published var scanState = ScanState()
    @Published var result: ScanResult?
    @Published var isScanning = false

    // Actors initialised on first use — stored as nonisolated lets on MainActor class is fine
    nonisolated let hashAnalyzer    = HashAnalyzer()
    nonisolated let visionAnalyzer  = VisionAnalyzer()
    nonisolated let qualityAnalyzer = QualityAnalyzer()
    nonisolated let videoAnalyzer   = VideoAnalyzer()
    nonisolated let clusterer       = DuplicateClusterer()
    nonisolated let junkGrouper     = JunkGrouper()

    private var scanTask: Task<Void, Never>?

    // MARK: - Control

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        scanTask = Task { await self.performScan() }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanState.phase = .idle
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

            // 4. Vision analysis (feature prints + aesthetics + classifications)
            scanState.update(phase: .visionAnalysis, processed: 0, total: assets.count)
            var visionResults: [String: VisionAnalyzer.VisionResult] = [:]
            await withTaskGroup(of: (String, VisionAnalyzer.VisionResult).self) { group in
                for asset in assets {
                    group.addTask {
                        let vr = await self.visionAnalyzer.analyse(asset: asset.phAsset)
                        return (asset.id, vr)
                    }
                }
                var processed = 0
                for await (id, vr) in group {
                    visionResults[id] = vr
                    processed += 1
                    if processed % 20 == 0 {
                        scanState.update(phase: .visionAnalysis, processed: processed, total: assets.count)
                    }
                }
            }

            // Apply vision results to assets
            for asset in assets {
                if let vr = visionResults[asset.id] {
                    asset.featurePrint    = vr.featurePrint
                    asset.classifications = vr.classifications
                    asset.detectedText    = vr.hasText
                    asset.faceCount       = vr.faceCount
                }
            }
            guard !Task.isCancelled else { return }

            // 5. Quality scoring (uses vision results already stored on asset)
            scanState.update(phase: .qualityScoring, processed: 0, total: assets.count)
            await withTaskGroup(of: (String, QualityScore).self) { group in
                for asset in assets {
                    let vr = visionResults[asset.id] ?? VisionAnalyzer.VisionResult()
                    group.addTask {
                        let score = await self.qualityAnalyzer.score(asset: asset.phAsset,
                                                                     visionResult: vr)
                        return (asset.id, score)
                    }
                }
                var processed = 0
                for await (id, score) in group {
                    assets.first { $0.id == id }?.qualityScore = score
                    processed += 1
                    if processed % 50 == 0 {
                        scanState.update(phase: .qualityScoring, processed: processed, total: assets.count)
                    }
                }
            }
            guard !Task.isCancelled else { return }

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

        } catch {
            scanState.phase = .failed
            scanState.error = error
            isScanning = false
        }
    }

    // MARK: - Video Groups

    private func buildVideoGroups(videoAssets: [PHAsset]) async -> [MediaGroup] {
        var groups: [MediaGroup] = []

        let accidental = videoAnalyzer.accidentalClips(assets: videoAssets)
        if !accidental.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.accidentalShot),
                assets: accidental.map { MediaAsset(phAsset: $0) },
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(accidental)
            ))
        }

        let screenRecs = videoAnalyzer.screenRecordings(assets: videoAssets)
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
