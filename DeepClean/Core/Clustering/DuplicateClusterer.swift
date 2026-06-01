import Foundation
import Photos
import Vision

// MARK: - Duplicate Clusterer
// Groups MediaAssets into clusters by exact hash, near-duplicate feature prints,
// and temporal burst proximity. Handles WhatsApp and cross-album detection.

struct DuplicateClusterer {

    // Feature print distance thresholds
    static let exactDuplicateThreshold: Float = 0.05
    static let nearDuplicateThreshold: Float  = 0.25
    static let similarShotThreshold: Float    = 0.45

    // Burst: >2 photos within this window
    static let burstTimeWindowSeconds: Double = 2.0

    // MARK: - Main Cluster Entry Point

    func cluster(
        assets: [MediaAsset],
        hashGroups: [String: [PHAsset]]
    ) -> [MediaGroup] {

        var groups: [MediaGroup] = []
        var usedIDs = Set<String>()

        let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

        // 1. Exact hash duplicates
        for (_, phAssets) in hashGroups where phAssets.count > 1 {
            let mediaAssets = phAssets.compactMap { assetMap[$0.localIdentifier] }
            guard mediaAssets.count > 1 else { continue }

            let hasWhatsApp = mediaAssets.contains(\.isWhatsApp)
            let type: SimilarityType = hasWhatsApp ? .whatsAppDuplicate : .exactDuplicate
            let crossAlbum = Set(mediaAssets.flatMap(\.sourceAlbums)).count > 1

            let finalType: SimilarityType = crossAlbum ? .crossAlbumDuplicate : type
            let sizeMB = estimatedSizeMB(assets: mediaAssets)

            let group = MediaGroup(
                groupType: .duplicates(finalType),
                assets: mediaAssets,
                confidence: finalType.confidence,
                estimatedSizeMB: sizeMB
            )
            groups.append(group)
            mediaAssets.forEach { usedIDs.insert($0.id) }
        }

        // 2. Feature print similarity clustering (unused assets only)
        let remaining = assets.filter { !usedIDs.contains($0.id) && $0.featurePrint != nil }
        let featureGroups = featurePrintClusters(assets: remaining)

        for cluster in featureGroups {
            guard cluster.count > 1 else { continue }

            let dist = averageDistance(cluster)
            let type: SimilarityType = dist < nearDuplicateThreshold ? .nearDuplicate : .similarShot
            let confidence = type.confidence

            let group = MediaGroup(
                groupType: .duplicates(type),
                assets: cluster,
                confidence: confidence,
                estimatedSizeMB: estimatedSizeMB(assets: cluster)
            )
            groups.append(group)
            cluster.forEach { usedIDs.insert($0.id) }
        }

        // 3. Burst sequences (temporal clustering on remaining assets)
        let afterFeature = assets.filter { !usedIDs.contains($0.id) }
        let bursts = burstClusters(assets: afterFeature)

        for burst in bursts {
            guard burst.count > 2 else { continue }
            let group = MediaGroup(
                groupType: .duplicates(.burstSequence),
                assets: burst,
                confidence: .safeToDelete,
                estimatedSizeMB: estimatedSizeMB(assets: burst)
            )
            groups.append(group)
            burst.forEach { usedIDs.insert($0.id) }
        }

        return groups.sorted { $0.estimatedSizeMB > $1.estimatedSizeMB }
    }

    // MARK: - Feature Print Clustering (greedy nearest-neighbour)

    private func featurePrintClusters(assets: [MediaAsset]) -> [[MediaAsset]] {
        var clusters: [[MediaAsset]] = []
        var assigned = Set<String>()

        for i in 0..<assets.count {
            let a = assets[i]
            guard !assigned.contains(a.id), let fpA = a.featurePrint else { continue }

            var cluster = [a]
            assigned.insert(a.id)

            for j in (i+1)..<assets.count {
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
        var currentBurst: [MediaAsset] = []

        for asset in sorted {
            if currentBurst.isEmpty {
                currentBurst.append(asset)
                continue
            }
            let last = currentBurst.last!
            let gap = asset.phAsset.creationDate?.timeIntervalSince(last.phAsset.creationDate ?? .distantPast) ?? 999
            if gap <= Self.burstTimeWindowSeconds {
                currentBurst.append(asset)
            } else {
                if currentBurst.count > 2 { clusters.append(currentBurst) }
                currentBurst = [asset]
            }
        }
        if currentBurst.count > 2 { clusters.append(currentBurst) }

        return clusters
    }

    // MARK: - Helpers

    private func averageDistance(_ assets: [MediaAsset]) -> Float {
        guard assets.count > 1 else { return 0 }
        var total: Float = 0
        var count = 0
        for i in 0..<assets.count {
            for j in (i+1)..<assets.count {
                guard let a = assets[i].featurePrint, let b = assets[j].featurePrint else { continue }
                var dist: Float = 0
                try? a.computeDistance(&dist, to: b)
                total += dist
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : 0
    }

    private func estimatedSizeMB(assets: [MediaAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let resources = PHAssetResource.assetResources(for: a.phAsset)
            let bytes = resources.first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }
}

// MARK: - Junk Grouper

struct JunkGrouper {

    func group(assets: [MediaAsset]) -> [MediaGroup] {
        var groups: [MediaGroup] = []

        // Screenshots
        let screenshots = assets.filter { $0.qualityScore?.isUtility == true && !$0.qualityScore!.hasBlur }
        if !screenshots.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.screenshot),
                assets: screenshots,
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(screenshots)
            ))
        }

        // Blurry
        let blurry = assets.filter { $0.qualityScore?.hasBlur == true && $0.qualityScore?.isUtility == false }
        if !blurry.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.blurry),
                assets: blurry,
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(blurry)
            ))
        }

        // Junk shots (accidental / body parts)
        let junk = assets.filter { $0.qualityScore?.isJunkShot == true && $0.qualityScore?.hasBlur == false }
        if !junk.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.accidentalShot),
                assets: junk,
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(junk)
            ))
        }

        // Bad exposure
        let badExposure = assets.filter {
            guard let q = $0.qualityScore else { return false }
            return q.exposure < 0.2 && !q.hasBlur && !q.isUtility && !q.isJunkShot
        }
        if !badExposure.isEmpty {
            groups.append(MediaGroup(
                groupType: .junk(.badExposure),
                assets: badExposure,
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(badExposure)
            ))
        }

        return groups.sorted { $0.estimatedSizeMB > $1.estimatedSizeMB }
    }

    private func sizeMB(_ assets: [MediaAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let res = PHAssetResource.assetResources(for: a.phAsset)
            let bytes = res.first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }
}

// MARK: - Collection helper

private extension Collection {
    func contains(_ keyPath: KeyPath<Element, Bool>) -> Bool {
        contains { $0[keyPath: keyPath] }
    }
}
