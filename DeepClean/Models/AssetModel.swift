import Foundation
import Photos
import Vision

// MARK: - Asset Quality Score

struct QualityScore: Codable {
    let sharpness: Float        // 0-1, Laplacian variance normalised
    let exposure: Float         // 0-1, histogram balance
    let aesthetics: Float       // 0-1, Apple VNImageAesthetics model
    let faceQuality: Float      // 0-1, best face sharpness + eyes open
    let noiseLevel: Float       // 0-1, lower is better
    let hasBlur: Bool
    let isJunkShot: Bool        // accidental / body-part / no-subject shot
    let isUtility: Bool         // screenshot, document, receipt

    var composite: Float {
        guard !hasBlur && !isJunkShot else { return 0 }
        return aesthetics * 0.35
             + sharpness  * 0.30
             + exposure   * 0.20
             + faceQuality * 0.15
    }
}

// MARK: - Media Asset

final class MediaAsset: Identifiable, Hashable {
    let id: String
    let phAsset: PHAsset
    var sha256: String?
    var featurePrint: VNFeaturePrintObservation?
    var qualityScore: QualityScore?
    var classifications: [String] = []
    var detectedText: Bool = false
    var faceCount: Int = 0
    var sourceAlbums: [String] = []     // all album names this appears in
    var isCloudOnly: Bool = false
    var isWhatsApp: Bool = false
    var isFavorite: Bool = false

    init(phAsset: PHAsset) {
        self.id = phAsset.localIdentifier
        self.phAsset = phAsset
        self.isFavorite = phAsset.isFavorite
        self.isCloudOnly = (phAsset.sourceType == .typeCloudShared)
                        || !phAsset.isDownloadedToDevice
    }

    static func == (lhs: MediaAsset, rhs: MediaAsset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension PHAsset {
    var isDownloadedToDevice: Bool {
        let resource = PHAssetResource.assetResources(for: self)
        return resource.contains { $0.value(forKey: "locallyAvailable") as? Bool == true }
    }
}

// MARK: - Duplicate / Similarity Type

enum SimilarityType: String, CaseIterable {
    case exactDuplicate     = "Exact Duplicate"
    case nearDuplicate      = "Near Duplicate"
    case similarShot        = "Similar Shot"
    case burstSequence      = "Burst Sequence"
    case crossAlbumDuplicate = "Cross-Album Duplicate"
    case whatsAppDuplicate  = "WhatsApp Duplicate"

    var confidence: GroupConfidence {
        switch self {
        case .exactDuplicate, .crossAlbumDuplicate: return .safeToDelete
        case .nearDuplicate, .whatsAppDuplicate:    return .safeToDelete
        case .burstSequence:                         return .safeToDelete
        case .similarShot:                           return .reviewRecommended
        }
    }
}

// MARK: - Junk Type

enum JunkType: String, CaseIterable {
    case blurry         = "Blurry Photo"
    case badExposure    = "Bad Exposure"
    case accidentalShot = "Accidental Shot"
    case bodyPartShot   = "Body Part Shot"
    case screenshot     = "Screenshot"
    case screenRecording = "Screen Recording"
    case lowQuality     = "Low Quality"
    case receipt        = "Receipt / Document"

    var confidence: GroupConfidence {
        switch self {
        case .blurry, .accidentalShot, .bodyPartShot: return .safeToDelete
        case .screenshot, .screenRecording:           return .reviewRecommended
        case .badExposure, .lowQuality:               return .reviewRecommended
        case .receipt:                                 return .keepRecommended
        }
    }
}

// MARK: - Group Confidence

enum GroupConfidence: Int, Comparable {
    case safeToDelete = 0
    case reviewRecommended = 1
    case keepRecommended = 2

    static func < (lhs: GroupConfidence, rhs: GroupConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .safeToDelete:      return "Safe to Delete"
        case .reviewRecommended: return "Review Recommended"
        case .keepRecommended:   return "Keep Recommended"
        }
    }

    var color: String {
        switch self {
        case .safeToDelete:      return "red"
        case .reviewRecommended: return "orange"
        case .keepRecommended:   return "green"
        }
    }
}
