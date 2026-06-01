import Foundation
import Photos

// MARK: - Scan Persistence
// Saves scan results to disk so the app doesn't rescan on every launch.
// Stores only asset IDs + group metadata — PHAssets are re-fetched on load.

struct PersistedGroup: Codable {
    let groupTypeKey: String    // e.g. "duplicate.exactDuplicate" or "junk.blurry"
    let assetIDs: [String]
    let confidence: Int         // GroupConfidence rawValue
    let estimatedSizeMB: Double
}

struct PersistedScanResult: Codable {
    let scanDate: Date
    let groups: [PersistedGroup]
    let totalAssetsScanned: Int
    let iCloudOnlyCount: Int
    let whatsAppCount: Int
    let estimatedSavingsBytes: Int64
    let scanDuration: TimeInterval
}

final class ScanPersistence {

    static let shared = ScanPersistence()
    private let fileName = "last_scan.json"

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    // MARK: - Save

    func save(_ result: ScanResult) {
        let persisted = PersistedScanResult(
            scanDate: Date(),
            groups: result.groups.compactMap { group in
                PersistedGroup(
                    groupTypeKey: typeKey(for: group.groupType),
                    assetIDs: group.assets.map(\.id),
                    confidence: group.confidence.rawValue,
                    estimatedSizeMB: group.estimatedSizeMB
                )
            },
            totalAssetsScanned: result.totalAssetsScanned,
            iCloudOnlyCount: result.iCloudOnlyCount,
            whatsAppCount: result.whatsAppCount,
            estimatedSavingsBytes: result.estimatedSavingsBytes,
            scanDuration: result.scanDuration
        )
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Load

    func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(PersistedScanResult.self, from: data)
        else { return nil }

        // Only use cache if it's less than 24 hours old
        let age = Date().timeIntervalSince(persisted.scanDate)
        guard age < 86400 else { clear(); return nil }

        var result = ScanResult()
        result.totalAssetsScanned   = persisted.totalAssetsScanned
        result.iCloudOnlyCount      = persisted.iCloudOnlyCount
        result.whatsAppCount        = persisted.whatsAppCount
        result.estimatedSavingsBytes = persisted.estimatedSavingsBytes
        result.scanDuration         = persisted.scanDuration

        for pg in persisted.groups {
            let phAssets = fetchAssets(ids: pg.assetIDs)
            guard !phAssets.isEmpty else { continue }
            let mediaAssets = phAssets.map { MediaAsset(phAsset: $0) }
            let confidence  = GroupConfidence(rawValue: pg.confidence) ?? .reviewRecommended
            let groupType   = parseType(pg.groupTypeKey)

            result.groups.append(MediaGroup(
                groupType: groupType,
                assets: mediaAssets,
                confidence: confidence,
                estimatedSizeMB: pg.estimatedSizeMB
            ))
        }
        return result.groups.isEmpty ? nil : result
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var hasCachedResult: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Helpers

    private func fetchAssets(ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        return assets
    }

    private func typeKey(for type: MediaGroup.GroupType) -> String {
        switch type {
        case .duplicates(let s): return "duplicate.\(s.rawValue)"
        case .junk(let j):       return "junk.\(j.rawValue)"
        case .whatsApp(let w):   return "whatsapp.\(w.rawValue)"
        case .largeFiles:        return "largeFiles"
        case .contacts:          return "contacts"
        }
    }

    private func parseType(_ key: String) -> MediaGroup.GroupType {
        if key.hasPrefix("duplicate."),
           let s = SimilarityType(rawValue: String(key.dropFirst("duplicate.".count))) {
            return .duplicates(s)
        }
        if key.hasPrefix("junk."),
           let j = JunkType(rawValue: String(key.dropFirst("junk.".count))) {
            return .junk(j)
        }
        if key.hasPrefix("whatsapp."),
           let w = MediaGroup.WhatsAppGroupType(rawValue: String(key.dropFirst("whatsapp.".count))) {
            return .whatsApp(w)
        }
        return .junk(.lowQuality)
    }
}
