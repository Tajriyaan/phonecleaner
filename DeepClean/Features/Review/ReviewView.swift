import SwiftUI
import Photos

// MARK: - Review View
// Shows all scan groups organized by confidence tier.
// User reviews each group, adjusts selections, then commits deletion.

struct ReviewView: View {
    @EnvironmentObject var scanEngine: ScanEngine
    @State private var selectedGroup: MediaGroup?
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showingSuccess = false

    private var result: ScanResult? { scanEngine.result }

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            if let result {
                if result.groups.isEmpty {
                    emptyState
                } else {
                    groupList(result: result)
                }
            } else {
                Text("No scan results. Run a scan first.")
                    .foregroundColor(Theme.Colors.textSecondary)
            }

            // Delete overlay
            if isDeleting {
                deletingOverlay
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if let result, !result.selectedForDeletion.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    deleteButton(result: result)
                }
            }
        }
        .alert("Confirm Deletion", isPresented: $showingDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) { commitDeletion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let result {
                Text("Move \(result.selectedForDeletion.count) items to Trash?\nYou can recover them from Photos for 30 days.")
            }
        }
        .navigationDestination(item: $selectedGroup) { group in
            GroupDetailView(group: group)
                .environmentObject(scanEngine)
        }
        .overlay {
            if showingSuccess { successOverlay }
        }
    }

    // MARK: - Group List

    private func groupList(result: ScanResult) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {

                // Savings summary banner
                savingsBanner(result: result)

                // Groups by confidence tier
                ForEach([GroupConfidence.safeToDelete, .reviewRecommended, .keepRecommended], id: \.self) { tier in
                    let groups = result.groups.filter { $0.confidence == tier }
                    if !groups.isEmpty {
                        confidenceSection(tier: tier, groups: groups)
                    }
                }
                .id(result.groups.count) // force list refresh when groups change

                Spacer(minLength: 100)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
        }
    }

    // MARK: - Savings Banner

    private func savingsBanner(result: ScanResult) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(Theme.Colors.safe)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Free up %.1f GB", result.selectedSizeMB / 1024))
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
                Text("\(result.selectedForDeletion.count) items selected for deletion")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.safe.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.safe.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Confidence Section

    private func confidenceSection(tier: GroupConfidence, groups: [MediaGroup]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Circle()
                    .fill(tier.themeColor)
                    .frame(width: 8, height: 8)
                Text(tier.label)
                    .font(Theme.Typography.headline)
                    .foregroundColor(tier.themeColor)
                Spacer()
                Text("\(groups.count) groups")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textTertiary)
            }

            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(groups) { group in
                    groupRow(group: group)
                }
            }
        }
    }

    // MARK: - Group Row

    private func groupRow(group: MediaGroup) -> some View {
        Button { selectedGroup = group } label: {
            HStack(spacing: Theme.Spacing.md) {
                // Single thumbnail only — lazy loaded, no stack overhead
                thumbnailStack(group: group)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(Theme.Typography.headline)
                        .foregroundColor(Theme.Colors.textPrimary)
                    Text("\(group.assets.count) items · \(String(format: "%.1f MB", group.estimatedSizeMB))")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textSecondary)
                    Text("\(group.selectedForDeletion.count) selected for deletion")
                        .font(Theme.Typography.tiny)
                        .foregroundColor(group.confidence.themeColor)
                }
                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Theme.Colors.textTertiary)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thumbnail Stack

    private func thumbnailStack(group: MediaGroup) -> some View {
        // Single thumbnail — stacking 3 was causing slow scrolling
        Group {
            if let first = group.assets.first {
                PhotoThumbnailView(asset: first.phAsset)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
        }
        .frame(width: 56, height: 56)
    }

    // MARK: - Delete Button

    private func deleteButton(result: ScanResult) -> some View {
        Button {
            showingDeleteConfirmation = true
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "trash.fill")
                Text("Move \(result.selectedForDeletion.count) Items to Trash")
                    .font(Theme.Typography.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.danger)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - Deletion

    private func commitDeletion() {
        isDeleting = true
        Task {
            do {
                try await scanEngine.deleteAllSelected()
                await MainActor.run {
                    isDeleting = false
                    showingSuccess = true
                }
            } catch {
                await MainActor.run { isDeleting = false }
            }
        }
    }

    // MARK: - Overlays

    private var deletingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
                Text("Moving to Trash…")
                    .font(Theme.Typography.headline)
                    .foregroundColor(.white)
            }
        }
    }

    private var successOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.Colors.safe)
                Text("Done! Items moved to Trash.")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.surface)
            .clipShape(Capsule())
            .shadow(radius: 10)
            .padding(.bottom, 40)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    showingSuccess = false
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Gradients.safe)
            Text("All Clean!")
                .font(Theme.Typography.title)
                .foregroundColor(Theme.Colors.textPrimary)
            Text("No duplicates or junk found.")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textSecondary)
        }
    }
}
