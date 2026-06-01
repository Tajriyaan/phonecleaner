import SwiftUI
import Photos

// MARK: - Group Detail View
// Side-by-side / grid comparison of all photos in a group.
// User can change the "keep" selection and commit deletion for just this group.

struct GroupDetailView: View {
    @ObservedObject var group: MediaGroup
    @EnvironmentObject var scanEngine: ScanEngine
    @State private var selectedAssetID: String?
    @State private var showingDeleteConfirmation = false
    @State private var deleted = false

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if group.assets.count == 2 {
                    sideBySideView
                } else {
                    gridView
                }

                bottomBar
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .alert("Move to Trash?", isPresented: $showingDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) { commitGroupDeletion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(group.selectedForDeletion.count) items to Trash. Recoverable for 30 days in Photos.")
        }
        .overlay {
            if deleted {
                deletedBanner
            }
        }
    }

    // MARK: - Side-by-Side (2 photos)

    private var sideBySideView: some View {
        HStack(spacing: 2) {
            ForEach(group.assets) { asset in
                assetCard(asset: asset, fullHeight: true)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Grid (3+ photos)

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 2) {
                ForEach(group.assets) { asset in
                    assetCard(asset: asset, fullHeight: false)
                        .aspectRatio(1, contentMode: .fill)
                }
            }
        }
    }

    // MARK: - Asset Card

    private func assetCard(asset: MediaAsset, fullHeight: Bool) -> some View {
        let isSelected = group.selectedForDeletion.contains(asset.id)
        let isBest = group.bestAsset?.id == asset.id

        return ZStack(alignment: .top) {
            PhotoThumbnailView(asset: asset.phAsset)
                .frame(maxWidth: .infinity, maxHeight: fullHeight ? .infinity : nil)
                .overlay(
                    isSelected
                    ? Color.red.opacity(0.35)
                    : isBest
                    ? Color.green.opacity(0.1)
                    : Color.clear
                )

            // Quality score overlay
            VStack {
                HStack {
                    if isBest {
                        Label("Best", systemImage: "star.fill")
                            .font(Theme.Typography.tiny)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.Colors.safe)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Theme.Colors.danger)
                            .clipShape(Circle())
                    }
                }
                .padding(8)

                Spacer()

                // Quality bar
                if let q = asset.qualityScore {
                    qualityBar(score: q)
                }
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.25)) {
                if group.selectedForDeletion.contains(asset.id) {
                    group.selectedForDeletion.remove(asset.id)
                } else if !asset.isFavorite {
                    group.selectedForDeletion.insert(asset.id)
                }
            }
        }
    }

    // MARK: - Quality Bar

    private func qualityBar(score: QualityScore) -> some View {
        HStack(spacing: 4) {
            qualityPill(label: "Sharp", value: score.sharpness)
            qualityPill(label: "Exp",   value: score.exposure)
            if score.faceQuality > 0 {
                qualityPill(label: "Face", value: score.faceQuality)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private func qualityPill(label: String, value: Float) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Divider().background(Theme.Colors.separator)

            HStack(spacing: Theme.Spacing.md) {
                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.selectedForDeletion.count) selected for deletion")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textSecondary)
                    Text("Tap photo to toggle")
                        .font(Theme.Typography.tiny)
                        .foregroundColor(Theme.Colors.textTertiary)
                }
                Spacer()

                // Skip
                Button("Skip") {}
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textTertiary)

                // Delete this group
                if !group.selectedForDeletion.isEmpty {
                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Trash \(group.selectedForDeletion.count)")
                        }
                        .font(Theme.Typography.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Theme.Colors.danger)
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.md)
        }
        .background(Theme.Colors.surface)
    }

    // MARK: - Actions

    private func commitGroupDeletion() {
        Task {
            try? await scanEngine.deleteSelected(from: group)
            await MainActor.run { deleted = true }
        }
    }

    private var deletedBanner: some View {
        VStack {
            Spacer()
            Text("Moved to Trash ✓")
                .font(Theme.Typography.headline)
                .foregroundColor(.white)
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.safe)
                .clipShape(Capsule())
                .padding(.bottom, 60)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        deleted = false
                    }
                }
        }
    }
}
