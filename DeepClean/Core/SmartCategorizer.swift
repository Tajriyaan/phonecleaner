import Foundation
import Photos

// MARK: - Smart Category

struct SmartCategory: Identifiable, Codable, Hashable {
    static func == (lhs: SmartCategory, rhs: SmartCategory) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var isUserDefined: Bool
    var rules: [CategoryRule]
    var assetIDs: [String] = []

    var isEmpty: Bool { assetIDs.isEmpty }
    var count: Int { assetIDs.count }

    init(id: UUID = UUID(), name: String, icon: String,
         colorHex: String, isUserDefined: Bool = false,
         rules: [CategoryRule]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.isUserDefined = isUserDefined
        self.rules = rules
    }
}

// MARK: - Category Rule

enum CategoryRule: Codable, Hashable {
    case faceCount(min: Int, max: Int?)     // e.g. selfie = (1,1), group = (3, nil)
    case takenBetweenHours(from: Int, to: Int) // night = (20, 6)
    case fileSizeAboveMB(Double)
    case mediaType(photo: Bool, video: Bool)
    case hasGPSLocation(Bool)
    case albumContains(String)
    case subtype(PHAssetMediaSubtypeWrapper)
    case daysTaken(withinLast: Int)
    case olderThanDays(Int)
    case aspectRatio(kind: AspectKind)
    // Vision-based (populated from MediaAsset quality scores)
    case isBlurry
    case isDark
    case isOverexposed
    case hasTextContent
    case isObjectShot           // no face, no text = likely an object/product
    case isVeryShortVideo       // duration < 5 seconds

    enum AspectKind: String, Codable {
        case portrait, landscape, square
    }

    // Codable wrapper for PHAssetMediaSubtype (not Codable by default)
    enum PHAssetMediaSubtypeWrapper: String, Codable, Hashable {
        case photoScreenshot, photoPanorama, photoHDR, photoLive,
             videoHighFrameRate, videoTimelapse
    }
}

// MARK: - Smart Categorizer

struct SmartCategorizer {

    // MARK: - Built-in Smart Categories

    // Research-backed categories covering the most common photo cleanup needs.
    // All use metadata + Vision data already computed — zero extra image loading.
    static var builtInCategories: [SmartCategory] { [

        // ── Portrait / People ────────────────────────────────────────────────
        SmartCategory(name: "Selfies",
            icon: "person.fill.viewfinder", colorHex: "#FF6B9D",
            rules: [.faceCount(min: 1, max: 1), .aspectRatio(kind: .portrait)]),

        SmartCategory(name: "Group Photos",
            icon: "person.3.fill", colorHex: "#7C5CFC",
            rules: [.faceCount(min: 3, max: nil)]),

        SmartCategory(name: "Portrait Photos",
            icon: "person.crop.rectangle.fill", colorHex: "#A78BFA",
            rules: [.faceCount(min: 1, max: nil), .aspectRatio(kind: .portrait)]),

        SmartCategory(name: "No People",
            icon: "photo.fill", colorHex: "#34D399",
            rules: [.faceCount(min: 0, max: 0), .mediaType(photo: true, video: false)]),

        // ── Time-based ───────────────────────────────────────────────────────
        SmartCategory(name: "Night Photos",
            icon: "moon.stars.fill", colorHex: "#312E81",
            rules: [.takenBetweenHours(from: 20, to: 6)]),

        SmartCategory(name: "Morning Photos",
            icon: "sunrise.fill", colorHex: "#FCD34D",
            rules: [.takenBetweenHours(from: 6, to: 10)]),

        SmartCategory(name: "Recent (Last 7 Days)",
            icon: "clock.fill", colorHex: "#60A5FA",
            rules: [.daysTaken(withinLast: 7)]),

        SmartCategory(name: "Old Photos (1+ Year)",
            icon: "calendar.badge.clock", colorHex: "#9CA3AF",
            rules: [.olderThanDays(365)]),

        SmartCategory(name: "Forgotten Photos (3+ Years)",
            icon: "archivebox.fill", colorHex: "#6B7280",
            rules: [.olderThanDays(1095)]),

        // ── Location ─────────────────────────────────────────────────────────
        SmartCategory(name: "Travel Photos",
            icon: "airplane", colorHex: "#10B981",
            rules: [.hasGPSLocation(true)]),

        SmartCategory(name: "No Location",
            icon: "location.slash.fill", colorHex: "#4B5563",
            rules: [.hasGPSLocation(false), .mediaType(photo: true, video: false)]),

        // ── Format ───────────────────────────────────────────────────────────
        SmartCategory(name: "Panoramas",
            icon: "photo.on.rectangle", colorHex: "#06B6D4",
            rules: [.subtype(.photoPanorama)]),

        SmartCategory(name: "Square Photos",
            icon: "square.fill", colorHex: "#EC4899",
            rules: [.aspectRatio(kind: .square)]),

        SmartCategory(name: "Landscape Photos",
            icon: "rectangle.fill", colorHex: "#059669",
            rules: [.aspectRatio(kind: .landscape), .mediaType(photo: true, video: false)]),

        // ── Video ────────────────────────────────────────────────────────────
        SmartCategory(name: "All Videos",
            icon: "video.fill", colorHex: "#F59E0B",
            rules: [.mediaType(photo: false, video: true)]),

        SmartCategory(name: "Slow-Motion",
            icon: "gauge.with.dots.needle.33percent", colorHex: "#8B5CF6",
            rules: [.subtype(.videoHighFrameRate)]),

        SmartCategory(name: "Time-Lapse",
            icon: "timer", colorHex: "#D97706",
            rules: [.subtype(.videoTimelapse)]),

        // ── Storage ──────────────────────────────────────────────────────────
        SmartCategory(name: "Large Files (>10 MB)",
            icon: "arrow.up.doc.fill", colorHex: "#F87171",
            rules: [.fileSizeAboveMB(10)]),

        SmartCategory(name: "Huge Files (>50 MB)",
            icon: "externaldrive.fill", colorHex: "#EF4444",
            rules: [.fileSizeAboveMB(50)]),

        // ── System subtypes ──────────────────────────────────────────────────
        SmartCategory(name: "Live Photos",
            icon: "livephoto", colorHex: "#F472B6",
            rules: [.subtype(.photoLive)]),

        SmartCategory(name: "HDR Photos",
            icon: "sparkles.rectangle.stack.fill", colorHex: "#FBBF24",
            rules: [.subtype(.photoHDR)]),

        SmartCategory(name: "Screenshots",
            icon: "iphone", colorHex: "#64748B",
            rules: [.subtype(.photoScreenshot)]),

        // ── Vision quality categories ─────────────────────────────────────
        SmartCategory(name: "Blurry / Out of Focus",
            icon: "aqi.medium", colorHex: "#94A3B8",
            rules: [.isBlurry]),

        SmartCategory(name: "Dark / Underexposed",
            icon: "moon.circle.fill", colorHex: "#1E293B",
            rules: [.isDark]),

        SmartCategory(name: "Washed Out / Overexposed",
            icon: "sun.max.fill", colorHex: "#FDE68A",
            rules: [.isOverexposed]),

        SmartCategory(name: "Object & Product Shots",
            icon: "cube.fill", colorHex: "#F97316",
            rules: [.isObjectShot, .mediaType(photo: true, video: false)]),

        SmartCategory(name: "Text & Signs",
            icon: "text.viewfinder", colorHex: "#0EA5E9",
            rules: [.hasTextContent, .mediaType(photo: true, video: false)]),

        // ── High-volume clutter (mass deletion targets) ───────────────────

        // People photograph receipts, price tags, parking meters, signs,
        // menus, QR codes — then forget about them. High text + portrait + old = temp reference.
        SmartCategory(name: "Quick Reference Shots",
            icon: "doc.text.magnifyingglass", colorHex: "#D97706",
            rules: [.hasTextContent, .aspectRatio(kind: .portrait),
                    .faceCount(min: 0, max: 0), .olderThanDays(30)]),

        // Whiteboard photos, meeting notes, handwritten notes, class slides
        SmartCategory(name: "Meeting & Notes",
            icon: "rectangle.and.pencil.and.ellipsis", colorHex: "#0284C7",
            rules: [.hasTextContent, .aspectRatio(kind: .landscape),
                    .faceCount(min: 0, max: 0)]),

        // Photos taken at night at events — almost always dark and useless
        SmartCategory(name: "Dark Event Photos",
            icon: "sparkles", colorHex: "#1E1B4B",
            rules: [.isDark, .takenBetweenHours(from: 19, to: 4),
                    .mediaType(photo: true, video: false)]),

        // Videos longer than 5 minutes — biggest storage hogs
        SmartCategory(name: "Long Videos (5+ min)",
            icon: "clock.badge.fill", colorHex: "#BE123C",
            rules: [.mediaType(photo: false, video: true), .fileSizeAboveMB(100)]),

        // Very short videos under 5 seconds — accidental presses
        SmartCategory(name: "Short Accidental Videos",
            icon: "video.slash.fill", colorHex: "#64748B",
            rules: [.mediaType(photo: false, video: true), .fileSizeAboveMB(0), .isVeryShortVideo]),

        // Photos from 3+ years ago with low quality — likely junk that survived
        SmartCategory(name: "Old Low-Quality Photos",
            icon: "clock.arrow.circlepath", colorHex: "#78716C",
            rules: [.olderThanDays(1095), .isBlurry]),

        // Forward/meme detection: text-heavy + not a screenshot = likely forwarded image
        SmartCategory(name: "Memes & Forwards",
            icon: "arrowshape.turn.up.right.fill", colorHex: "#7E22CE",
            rules: [.hasTextContent, .isObjectShot]),  // text + no face = forwarded content

        // Duplicate-like: same location GPS within minutes
        SmartCategory(name: "Repeated Location Shots",
            icon: "location.north.line.fill", colorHex: "#0F766E",
            rules: [.hasGPSLocation(true), .faceCount(min: 0, max: 0),
                    .mediaType(photo: true, video: false)]),

    ] }

    // MARK: - Apply Rules

    struct VisionSnapshot {
        var faceCount: Int = 0
        var isBlurry: Bool = false
        var isDark: Bool = false
        var isOverexposed: Bool = false
        var hasText: Bool = false
    }

    static func apply(category: SmartCategory, to assets: [PHAsset],
                      vision: [String: VisionSnapshot]) -> [String] {
        assets.compactMap { asset in
            matches(asset: asset, rules: category.rules, vision: vision[asset.localIdentifier] ?? VisionSnapshot())
                ? asset.localIdentifier : nil
        }
    }

    static func applyAll(categories: inout [SmartCategory],
                         to assets: [PHAsset],
                         visionFaceCounts: [String: Int],
                         mediaAssets: [MediaAsset] = []) {
        // Build vision snapshot from MediaAsset data
        var snapshots: [String: VisionSnapshot] = [:]
        for ma in mediaAssets {
            snapshots[ma.id] = VisionSnapshot(
                faceCount:   ma.faceCount,
                isBlurry:    ma.qualityScore?.hasBlur ?? false,
                isDark:      (ma.qualityScore?.exposure ?? 0.5) < 0.2,
                isOverexposed: (ma.qualityScore?.exposure ?? 0.5) > 0.85,
                hasText:     ma.detectedText
            )
        }
        // Fallback: face count from dictionary if no MediaAsset
        for (id, count) in visionFaceCounts where snapshots[id] == nil {
            snapshots[id] = VisionSnapshot(faceCount: count)
        }

        for i in categories.indices {
            categories[i].assetIDs = apply(
                category: categories[i], to: assets, vision: snapshots)
        }
    }

    // MARK: - Rule Matching

    static func matches(asset: PHAsset, rules: [CategoryRule],
                        vision: VisionSnapshot) -> Bool {
        rules.allSatisfy { matchesRule(asset: asset, rule: $0, vision: vision) }
    }

    private static func matchesRule(asset: PHAsset, rule: CategoryRule,
                                     vision: VisionSnapshot) -> Bool {
        switch rule {

        case .faceCount(let min, let max):
            let count = vision.faceCount
            if count < min { return false }
            if let max, count > max { return false }
            return true

        case .isBlurry:        return vision.isBlurry
        case .isDark:          return vision.isDark
        case .isOverexposed:   return vision.isOverexposed
        case .hasTextContent:  return vision.hasText && !asset.mediaSubtypes.contains(.photoScreenshot)
        case .isObjectShot:        return vision.faceCount == 0 && !vision.hasText
        case .isVeryShortVideo:    return asset.mediaType == .video && asset.duration < 5.0

        case .takenBetweenHours(let from, let to):
            guard let date = asset.creationDate else { return false }
            let hour = Calendar.current.component(.hour, from: date)
            if from <= to { return hour >= from && hour < to }
            return hour >= from || hour < to   // wraps midnight (e.g. 20–6)

        case .fileSizeAboveMB(let mb):
            let bytes = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return Double(bytes) / 1_048_576 > mb

        case .mediaType(let photo, let video):
            if photo && asset.mediaType == .image  { return true }
            if video && asset.mediaType == .video  { return true }
            return false

        case .hasGPSLocation(let required):
            return (asset.location != nil) == required

        case .albumContains:
            return true  // refined externally

        case .subtype(let wrapper):
            switch wrapper {
            case .photoScreenshot:    return asset.mediaSubtypes.contains(.photoScreenshot)
            case .photoPanorama:      return asset.mediaSubtypes.contains(.photoPanorama)
            case .photoHDR:           return asset.mediaSubtypes.contains(.photoHDR)
            case .photoLive:          return asset.mediaSubtypes.contains(.photoLive)
            case .videoHighFrameRate: return asset.mediaSubtypes.contains(.videoHighFrameRate)
            case .videoTimelapse:     return asset.mediaSubtypes.contains(.videoTimelapse)
            }

        case .daysTaken(let days):
            guard let date = asset.creationDate else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -abs(days), to: Date()) ?? Date()
            return date >= cutoff

        case .olderThanDays(let days):
            guard let date = asset.creationDate else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            return date < cutoff

        case .aspectRatio(let kind):
            let w = Double(asset.pixelWidth)
            let h = Double(asset.pixelHeight)
            guard h > 0 else { return false }
            let ratio = w / h
            switch kind {
            case .portrait:  return ratio < 0.85
            case .landscape: return ratio > 1.2
            case .square:    return ratio >= 0.85 && ratio <= 1.2
            }
        }
    }
}

// MARK: - Category Persistence

final class CategoryStore: ObservableObject {
    static let shared = CategoryStore()
    @Published var categories: [SmartCategory] = SmartCategorizer.builtInCategories

    private let key = "userDefinedCategories"

    init() { loadUserCategories() }

    func addUserCategory(_ category: SmartCategory) {
        categories.append(category)
        saveUserCategories()
    }

    func deleteUserCategory(id: UUID) {
        categories.removeAll { $0.id == id && $0.isUserDefined }
        saveUserCategories()
    }

    func updateAssetIDs(for categoryID: UUID, ids: [String]) {
        if let idx = categories.firstIndex(where: { $0.id == categoryID }) {
            categories[idx].assetIDs = ids
        }
    }

    private func saveUserCategories() {
        let user = categories.filter(\.isUserDefined)
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadUserCategories() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let user = try? JSONDecoder().decode([SmartCategory].self, from: data)
        else { return }
        categories = SmartCategorizer.builtInCategories + user
    }
}
