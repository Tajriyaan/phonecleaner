import SwiftUI

// MARK: - Category Builder
// Lets users create their own category with a name, icon, and simple rules.

struct CategoryBuilderView: View {
    @EnvironmentObject var store: CategoryStore
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var selectedIcon = "folder.fill"
    @State private var selectedColor = "#7C5CFC"
    @State private var selectedRules: Set<RulePreset> = []

    let icons = [
        "person.fill", "person.3.fill", "figure.walk", "heart.fill",
        "star.fill", "moon.fill", "sun.max.fill", "cloud.fill",
        "camera.fill", "photo.fill", "video.fill", "music.note",
        "doc.fill", "map.fill", "car.fill", "airplane",
        "fork.knife", "cup.and.saucer.fill", "gift.fill", "pawprint.fill"
    ]

    let colors = [
        "#7C5CFC", "#FC5CA0", "#34D399", "#FBBF24",
        "#F87171", "#60A5FA", "#A78BFA", "#10B981",
        "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {

                        // Preview card
                        previewCard

                        // Name
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Category Name")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textSecondary)
                            TextField("e.g. Beach Photos", text: $name)
                                .font(Theme.Typography.headline)
                                .foregroundColor(Theme.Colors.textPrimary)
                                .padding(Theme.Spacing.md)
                                .background(Theme.Colors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        }

                        // Icon picker
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Icon")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textSecondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                                      spacing: Theme.Spacing.sm) {
                                ForEach(icons, id: \.self) { icon in
                                    Button {
                                        selectedIcon = icon
                                    } label: {
                                        Image(systemName: icon)
                                            .font(.title2)
                                            .foregroundColor(selectedIcon == icon
                                                             ? Color(hex: selectedColor)
                                                             : Theme.Colors.textSecondary)
                                            .frame(width: 44, height: 44)
                                            .background(selectedIcon == icon
                                                        ? Color(hex: selectedColor).opacity(0.15)
                                                        : Theme.Colors.surface)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                                    }
                                }
                            }
                        }

                        // Color picker
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Color")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textSecondary)
                            HStack(spacing: Theme.Spacing.sm) {
                                ForEach(colors, id: \.self) { hex in
                                    Button {
                                        selectedColor = hex
                                    } label: {
                                        Circle()
                                            .fill(Color(hex: hex))
                                            .frame(width: 28, height: 28)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: selectedColor == hex ? 3 : 0)
                                                    .padding(2)
                                            )
                                    }
                                }
                            }
                        }

                        // Rules
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("What to Include")
                                .font(Theme.Typography.caption)
                                .foregroundColor(Theme.Colors.textSecondary)

                            LazyVStack(spacing: Theme.Spacing.xs) {
                                ForEach(RulePreset.allCases, id: \.self) { preset in
                                    ruleToggle(preset)
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(Theme.Spacing.md)
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(Theme.Typography.headline)
                        .foregroundColor(name.isEmpty ? Theme.Colors.textTertiary : Theme.Colors.accent)
                        .disabled(name.isEmpty)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Color(hex: selectedColor).opacity(0.2))
                    .frame(width: 52, height: 52)
                Image(systemName: selectedIcon)
                    .foregroundColor(Color(hex: selectedColor))
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Category Name" : name)
                    .font(Theme.Typography.headline)
                    .foregroundColor(name.isEmpty ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                Text(selectedRules.isEmpty ? "No rules set" : "\(selectedRules.count) rules")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Rule Toggle

    private func ruleToggle(_ preset: RulePreset) -> some View {
        let selected = selectedRules.contains(preset)
        return Button {
            if selected { selectedRules.remove(preset) }
            else        { selectedRules.insert(preset) }
        } label: {
            HStack {
                Image(systemName: preset.icon)
                    .foregroundColor(selected ? Color(hex: selectedColor) : Theme.Colors.textTertiary)
                    .frame(width: 20)
                Text(preset.label)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Color(hex: selectedColor) : Theme.Colors.textTertiary)
            }
            .padding(Theme.Spacing.sm)
            .background(selected ? Color(hex: selectedColor).opacity(0.1) : Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    private func save() {
        let rules: [CategoryRule] = selectedRules.flatMap(\.categoryRules)
        let category = SmartCategory(
            name: name,
            icon: selectedIcon,
            colorHex: selectedColor,
            isUserDefined: true,
            rules: rules
        )
        store.addUserCategory(category)
        dismiss()
    }
}

// MARK: - Rule Presets (simple, human-readable)

enum RulePreset: String, CaseIterable {
    case selfie         = "Selfies (1 face)"
    case group          = "Group photos (3+ faces)"
    case noFaces        = "No people in frame"
    case nightTime      = "Taken at night (8pm–6am)"
    case morning        = "Taken in morning (6am–12pm)"
    case withLocation   = "Has GPS location"
    case noLocation     = "No GPS location"
    case photosOnly     = "Photos only (no videos)"
    case videosOnly     = "Videos only"
    case largeFiles     = "Large files (>10 MB)"
    case hugeFiles      = "Huge files (>50 MB)"
    case oldPhotos      = "Older than 1 year"
    case veryOld        = "Older than 3 years"
    case recentWeek     = "Last 7 days"
    case recentMonth    = "Last 30 days"
    case square         = "Square format (social media)"
    case portrait       = "Portrait orientation"
    case landscape      = "Landscape orientation"

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .selfie:       return "person.fill.viewfinder"
        case .group:        return "person.3.fill"
        case .noFaces:      return "person.slash.fill"
        case .nightTime:    return "moon.fill"
        case .morning:      return "sunrise.fill"
        case .withLocation: return "location.fill"
        case .noLocation:   return "location.slash.fill"
        case .photosOnly:   return "photo.fill"
        case .videosOnly:   return "video.fill"
        case .largeFiles:   return "arrow.up.doc.fill"
        case .hugeFiles:    return "externaldrive.fill"
        case .oldPhotos:    return "clock.fill"
        case .veryOld:      return "calendar.badge.clock"
        case .recentWeek:   return "calendar"
        case .recentMonth:  return "calendar.circle.fill"
        case .square:       return "square.fill"
        case .portrait:     return "rectangle.portrait.fill"
        case .landscape:    return "rectangle.fill"
        }
    }

    var categoryRules: [CategoryRule] {
        switch self {
        case .selfie:       return [.faceCount(min: 1, max: 1)]
        case .group:        return [.faceCount(min: 3, max: nil)]
        case .noFaces:      return [.faceCount(min: 0, max: 0)]
        case .nightTime:    return [.takenBetweenHours(from: 20, to: 6)]
        case .morning:      return [.takenBetweenHours(from: 6, to: 12)]
        case .withLocation: return [.hasGPSLocation(true)]
        case .noLocation:   return [.hasGPSLocation(false)]
        case .photosOnly:   return [.mediaType(photo: true, video: false)]
        case .videosOnly:   return [.mediaType(photo: false, video: true)]
        case .largeFiles:   return [.fileSizeAboveMB(10)]
        case .hugeFiles:    return [.fileSizeAboveMB(50)]
        case .oldPhotos:    return [.daysTaken(withinLast: -365)]
        case .veryOld:      return [.daysTaken(withinLast: -1095)]
        case .recentWeek:   return [.daysTaken(withinLast: 7)]
        case .recentMonth:  return [.daysTaken(withinLast: 30)]
        case .square:       return [.aspectRatio(kind: .square)]
        case .portrait:     return [.aspectRatio(kind: .portrait)]
        case .landscape:    return [.aspectRatio(kind: .landscape)]
        }
    }
}
