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
            let prev = current.last!
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

struct JunkGrouper {

    func group(assets: [MediaAsset]) -> [MediaGroup] {
        var groups: [MediaGroup] = []

        let screenshots = assets.filter { $0.qualityScore?.isUtility == true }
        if !screenshots.isEmpty {
            groups.append(make(.junk(.screenshot), assets: screenshots, confidence: .reviewRecommended))
        }

        let blurry = assets.filter { $0.qualityScore?.hasBlur == true && $0.qualityScore?.isUtility != true }
        if !blurry.isEmpty {
            groups.append(make(.junk(.blurry), assets: blurry, confidence: .safeToDelete))
        }

        let junk = assets.filter {
            $0.qualityScore?.isJunkShot == true && $0.qualityScore?.hasBlur != true
        }
        if !junk.isEmpty {
            groups.append(make(.junk(.accidentalShot), assets: junk, confidence: .safeToDelete))
        }

        let badExposure = assets.filter {
            guard let q = $0.qualityScore else { return false }
            return q.exposure < 0.2 && !q.hasBlur && !q.isUtility && !q.isJunkShot
        }
        if !badExposure.isEmpty {
            groups.append(make(.junk(.badExposure), assets: badExposure, confidence: .reviewRecommended))
        }

        return groups.sorted { $0.estimatedSizeMB > $1.estimatedSizeMB }
    }

    private func make(_ type: MediaGroup.GroupType, assets: [MediaAsset],
                      confidence: GroupConfidence) -> MediaGroup {
        MediaGroup(groupType: type, assets: assets, confidence: confidence, estimatedSizeMB: sizeMB(assets))
    }

    private func sizeMB(_ assets: [MediaAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let bytes = PHAssetResource.assetResources(for: a.phAsset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }
}
