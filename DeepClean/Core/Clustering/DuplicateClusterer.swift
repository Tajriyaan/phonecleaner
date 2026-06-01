import Foundation
import Photos
import Vision

// MARK: - Duplicate Clusterer

struct DuplicateClusterer {

    static let nearDuplicateThreshold: Float = 0.25
    static let similarShotThreshold: Float   = 0.45
    static let burstTimeWindowSeconds: Double = 2.0

    // MARK: - Cluster Entry Point

    func cluster(assets: [MediaAsset], hashGroups: [String: [PHAsset]]) -> [MediaGroup] {
        var groups: [MediaGroup] = []
        var usedIDs = Set<String>()

        // Map PHAsset.localIdentifier → MediaAsset
        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

        // 1. Exact hash groups
        for (_, phAssets) in hashGroups where phAssets.count > 1 {
            // phAssets use localIdentifier which == MediaAsset.id
            let mediaAssets = phAssets.compactMap { assetMap[$0.localIdentifier] }
            guard mediaAssets.count > 1 else { continue }

            let hasWhatsApp   = mediaAssets.contains { $0.isWhatsApp }
            let crossAlbum    = Set(mediaAssets.flatMap(\.sourceAlbums)).count > 1
            let type: SimilarityType = crossAlbum ? .crossAlbumDuplicate
                                     : hasWhatsApp ? .whatsAppDuplicate
                                     : .exactDuplicate

            groups.append(MediaGroup(
                groupType: .duplicates(type),
                assets: mediaAssets,
                confidence: type.confidence,
                estimatedSizeMB: sizeMB(mediaAssets)
            ))
            mediaAssets.forEach { usedIDs.insert($0.id) }
        }

        // 2. Feature print similarity (remaining assets)
        let remaining = assets.filter { !usedIDs.contains($0.id) && $0.featurePrint != nil }
        for cluster in featurePrintClusters(assets: remaining) {
            guard cluster.count > 1 else { continue }
            let dist = averageDistance(cluster)
            let type: SimilarityType = dist < Self.nearDuplicateThreshold ? .nearDuplicate : .similarShot
            groups.append(MediaGroup(
                groupType: .duplicates(type),
                assets: cluster,
                confidence: type.confidence,
                estimatedSizeMB: sizeMB(cluster)
            ))
            cluster.forEach { usedIDs.insert($0.id) }
        }

        // 3. Burst sequences
        let afterFeature = assets.filter { !usedIDs.contains($0.id) }
        for burst in burstClusters(assets: afterFeature) where burst.count > 2 {
            groups.append(MediaGroup(
                groupType: .duplicates(.burstSequence),
                assets: burst,
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(burst)
            ))
            burst.forEach { usedIDs.insert($0.id) }
        }

        return groups.sorted { $0.estimatedSizeMB > $1.estimatedSizeMB }
    }

    // MARK: - Feature Print Clustering (greedy)

    private func featurePrintClusters(assets: [MediaAsset]) -> [[MediaAsset]] {
        var clusters: [[MediaAsset]] = []
        var assigned = Set<String>()

        for i in 0..<assets.count {
            let a = assets[i]
            guard !assigned.contains(a.id), let fpA = a.featurePrint else { continue }

            var cluster = [a]
            assigned.insert(a.id)

            for j in (i + 1)..<assets.count {
                let b = assets[j]
                guard !assigned.contains(b.id), let fpB = b.featurePrint else { continue }

                var dist: Float = 0
                try? fpA.computeDistance(&dist, to: fpB)
                if dist < Self.similarShotThreshold {
                    cluster.append(b)
                    assigned.insert(b.id)
                }
            }

            if cluster.count > 1 { clusters.append(cluster) }
        }
        return clusters
    }

    // MARK: - Burst Clustering

    private func burstClusters(assets: [MediaAsset]) -> [[MediaAsset]] {
        let sorted = assets
            .filter { $0.phAsset.mediaType == .image }
            .sorted { ($0.phAsset.creationDate ?? .distantPast) < ($1.phAsset.creationDate ?? .distantPast) }

        var clusters: [[MediaAsset]] = []
        var current: [MediaAsset] = []

        for asset in sorted {
            if current.isEmpty {
                current.append(asset); continue
            }
            guard let prev = current.last else { current = [asset]; continue }
            let gap  = asset.phAsset.creationDate?
                .timeIntervalSince(prev.phAsset.creationDate ?? .distantPast) ?? 999
            if gap <= Self.burstTimeWindowSeconds {
                current.append(asset)
            } else {
                if current.count > 2 { clusters.append(current) }
                current = [asset]
            }
        }
        if current.count > 2 { clusters.append(current) }
        return clusters
    }

    // MARK: - Helpers

    private func averageDistance(_ assets: [MediaAsset]) -> Float {
        var total: Float = 0
        var count = 0
        for i in 0..<assets.count {
            for j in (i + 1)..<assets.count {
                guard let a = assets[i].featurePrint,
                      let b = assets[j].featurePrint else { continue }
                var dist: Float = 0
                try? a.computeDistance(&dist, to: b)
                total += dist
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : 0
    }

    private func sizeMB(_ assets: [MediaAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let bytes = PHAssetResource.assetResources(for: a.phAsset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }
}

// MARK: - Junk Grouper
// Uses PHAsset metadata subtypes (instant, no image loading) + Vision quality scores.

struct JunkGrouper {

    func group(assets: [MediaAsset]) -> [MediaGroup] {
        var groups: [MediaGroup] = []
        var usedIDs = Set<String>()

        // ── Metadata-based categories (instant, no image loading needed) ──

        // Screenshots — use system subtype flag (most accurate)
        let screenshots = assets.filter {
            $0.phAsset.mediaSubtypes.contains(.photoScreenshot) ||
            $0.qualityScore?.isUtility == true
        }
        add(&groups, type: .screenshot, assets: screenshots, usedIDs: &usedIDs)

        // Screen recordings — filename pattern (RPReplay_*)
        let screenRecs = assets.filter {
            $0.phAsset.mediaType == .video &&
            PHAssetResource.assetResources(for: $0.phAsset).contains {
                $0.originalFilename.lowercased().hasPrefix("rpreplay_")
            }
        }
        add(&groups, type: .screenRecording, assets: screenRecs, usedIDs: &usedIDs)

        // Panoramas
        let panoramas = assets.filter { $0.phAsset.mediaSubtypes.contains(.photoPanorama) }
        add(&groups, type: .panorama, assets: panoramas, usedIDs: &usedIDs)

        // Slow-motion
        let slowmo = assets.filter { $0.phAsset.mediaSubtypes.contains(.videoHighFrameRate) }
        add(&groups, type: .slowMotion, assets: slowmo, usedIDs: &usedIDs)

        // Time-lapse
        let timelapse = assets.filter { $0.phAsset.mediaSubtypes.contains(.videoTimelapse) }
        add(&groups, type: .timeLapse, assets: timelapse, usedIDs: &usedIDs)

        // Live Photo video clips (the .mov component saved separately)
        let liveClips = assets.filter {
            $0.phAsset.mediaType == .video &&
            $0.phAsset.duration < 4.0 &&
            !usedIDs.contains($0.id)
        }.filter { asset in
            PHAssetResource.assetResources(for: asset.phAsset).contains {
                $0.type == .pairedVideo
            }
        }
        add(&groups, type: .livePhotoVideo, assets: liveClips, usedIDs: &usedIDs)

        // Saved from Messages (album name detection)
        let fromMessages = assets.filter {
            !usedIDs.contains($0.id) &&
            $0.sourceAlbums.contains {
                let name = $0.lowercased()
                return name.contains("message") || name.contains("whatsapp") ||
                       name.contains("telegram") || name.contains("signal")
            }
        }
        add(&groups, type: .savedFromMessages, assets: fromMessages, usedIDs: &usedIDs)

        // Saved from web / downloads (album name detection)
        let fromWeb = assets.filter {
            !usedIDs.contains($0.id) &&
            $0.sourceAlbums.contains {
                let name = $0.lowercased()
                return name.contains("download") || name.contains("saved") ||
                       name.contains("instagram") || name.contains("twitter") ||
                       name.contains("tiktok") || name.contains("facebook")
            }
        }
        add(&groups, type: .savedFromWeb, assets: fromWeb, usedIDs: &usedIDs)

        // ── Vision/quality-based categories ─────────────────────────────────

        // Blurry photos
        let blurry = assets.filter {
            !usedIDs.contains($0.id) &&
            $0.phAsset.mediaType == .image &&
            $0.qualityScore?.hasBlur == true
        }
        add(&groups, type: .blurry, assets: blurry, usedIDs: &usedIDs)

        // Accidental shots (junk shots detected by Vision)
        let accidental = assets.filter {
            !usedIDs.contains($0.id) &&
            $0.phAsset.mediaType == .image &&
            $0.qualityScore?.isJunkShot == true
        }
        add(&groups, type: .accidentalShot, assets: accidental, usedIDs: &usedIDs)

        // Bad exposure
        let badExposure = assets.filter {
            guard !usedIDs.contains($0.id), $0.phAsset.mediaType == .image,
                  let q = $0.qualityScore else { return false }
            return q.exposure < 0.2 && !q.hasBlur && !q.isUtility && !q.isJunkShot
        }
        add(&groups, type: .badExposure, assets: badExposure, usedIDs: &usedIDs)

        return groups.sorted { $0.estimatedSizeMB > $1.estimatedSizeMB }
    }

    private func add(_ groups: inout [MediaGroup],
                               type: JunkType,
                               assets: [MediaAsset],
                               usedIDs: inout Set<String>) {
        let fresh = assets.filter { !usedIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { usedIDs.insert($0.id) }
        groups.append(MediaGroup(
            groupType: .junk(type),
            assets: fresh,
            confidence: type.confidence,
            estimatedSizeMB: sizeMB(fresh)
        ))
    }

    private func sizeMB(_ assets: [MediaAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let bytes = PHAssetResource.assetResources(for: a.phAsset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }
}
