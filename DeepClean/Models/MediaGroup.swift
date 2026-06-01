import Foundation
import Photos

// MARK: - Media Group

final class MediaGroup: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    let groupType: GroupType
    let assets: [MediaAsset]
    let confidence: GroupConfidence
    var estimatedSizeMB: Double
    @Published var selectedForDeletion: Set<String>

    enum GroupType: Hashable {
        case duplicates(SimilarityType)
        case junk(JunkType)
        case largeFiles
        case contacts
    }

    var title: String {
        switch groupType {
        case .duplicates(let t): return t.rawValue
        case .junk(let t):       return t.rawValue
        case .largeFiles:        return "Large Files"
        case .contacts:          return "Duplicate Contacts"
        }
    }

    var bestAsset: MediaAsset? {
        assets.max { ($0.qualityScore?.composite ?? 0) < ($1.qualityScore?.composite ?? 0) }
    }

    var assetsToDelete: [MediaAsset] {
        assets.filter { selectedForDeletion.contains($0.id) }
    }

    init(groupType: GroupType, assets: [MediaAsset],
         confidence: GroupConfidence, estimatedSizeMB: Double) {
        self.groupType      = groupType
        self.assets         = assets
        self.confidence     = confidence
        self.estimatedSizeMB = estimatedSizeMB

        let best = assets.max { ($0.qualityScore?.composite ?? 0) < ($1.qualityScore?.composite ?? 0) }
        let toDelete = assets.filter { !$0.isFavorite && $0.id != best?.id }
        self.selectedForDeletion = Set(toDelete.map(\.id))
    }

    // MARK: Hashable / Equatable (identity-based)
    static func == (lhs: MediaGroup, rhs: MediaGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Scan Result

struct ScanResult {
    var groups: [MediaGroup] = []
    var totalAssetsScanned: Int = 0
    var iCloudOnlyCount: Int = 0
    var whatsAppCount: Int = 0
    var estimatedSavingsBytes: Int64 = 0
    var scanDuration: TimeInterval = 0

    var totalDuplicateGroups: Int {
        groups.filter {
            if case .duplicates = $0.groupType { return true }
            return false
        }.count
    }

    var totalJunkItems: Int {
        groups.filter {
            if case .junk = $0.groupType { return true }
            return false
        }.flatMap(\.assets).count
    }

    var totalSavingsMB: Double  { Double(estimatedSavingsBytes) / 1_048_576 }
    var totalSavingsGB: Double  { totalSavingsMB / 1024 }

    var selectedForDeletion: [MediaAsset] { groups.flatMap(\.assetsToDelete) }

    var selectedSizeMB: Double {
        groups.reduce(0) { acc, g in
            guard !g.assets.isEmpty else { return acc }
            let ratio = Double(g.selectedForDeletion.count) / Double(g.assets.count)
            return acc + g.estimatedSizeMB * ratio
        }
    }
}
