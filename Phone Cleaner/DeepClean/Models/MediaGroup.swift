import Foundation
import Photos

// MARK: - Media Group

final class MediaGroup: Identifiable, ObservableObject {
    let id = UUID()
    let groupType: GroupType
    let assets: [MediaAsset]
    let confidence: GroupConfidence
    var estimatedSizeMB: Double
    @Published var selectedForDeletion: Set<String>   // asset IDs

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
        assets.max { a, b in
            (a.qualityScore?.composite ?? 0) < (b.qualityScore?.composite ?? 0)
        }
    }

    var assetsToDelete: [MediaAsset] {
        assets.filter { selectedForDeletion.contains($0.id) }
    }

    init(groupType: GroupType, assets: [MediaAsset], confidence: GroupConfidence, estimatedSizeMB: Double) {
        self.groupType = groupType
        self.assets = assets
        self.confidence = confidence
        self.estimatedSizeMB = estimatedSizeMB

        // Pre-select all but the best asset (or all for junk)
        switch groupType {
        case .duplicates, .junk:
            let best = assets.max { a, b in
                (a.qualityScore?.composite ?? 0) < (b.qualityScore?.composite ?? 0)
            }
            let toDelete = assets.filter {
                !$0.isFavorite && $0.id != best?.id
            }
            self.selectedForDeletion = Set(toDelete.map(\.id))
        case .largeFiles, .contacts:
            self.selectedForDeletion = []
        }
    }
}

// MARK: - Scan Result

struct ScanResult {
    var groups: [MediaGroup] = []
    var totalAssetsScanned: Int = 0
    var totalDuplicateGroups: Int = 0
    var totalJunkItems: Int = 0
    var estimatedSavingsBytes: Int64 = 0
    var iCloudOnlyCount: Int = 0
    var whatsAppCount: Int = 0
    var scanDuration: TimeInterval = 0

    var totalSavingsMB: Double { Double(estimatedSavingsBytes) / 1_048_576 }
    var totalSavingsGB: Double { totalSavingsMB / 1024 }

    var groupsByConfidence: [GroupConfidence: [MediaGroup]] {
        Dictionary(grouping: groups) { $0.confidence }
    }

    var selectedForDeletion: [MediaAsset] {
        groups.flatMap(\.assetsToDelete)
    }

    var selectedSizeMB: Double {
        groups.reduce(0) { acc, g in
            let ratio = Double(g.selectedForDeletion.count) / Double(g.assets.count)
            return acc + g.estimatedSizeMB * ratio
        }
    }
}
