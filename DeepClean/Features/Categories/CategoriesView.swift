import SwiftUI
import Photos

// MARK: - Categories Tab
// Shows all smart + user-defined categories.
// Each category is browsable and bulk-deletable.

struct CategoriesView: View {
    @EnvironmentObject var scanEngine: ScanEngine
    @StateObject private var store = CategoryStore.shared
    @State private var showingBuilder = false
    @State private var selectedCategory: SmartCategory?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                if store.categories.filter({ !$0.isEmpty }).isEmpty && !scanEngine.isScanning {
                    emptyState
                } else {
                    categoryList
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingBuilder = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Theme.Gradients.accent)
                    }
                }
            }
            .sheet(isPresented: $showingBuilder) {
                CategoryBuilderView()
                    .environmentObject(store)
            }
            .navigationDestination(item: $selectedCategory) { cat in
                CategoryDetailView(category: cat)
                    .environmentObject(store)
            }
        }
    }

    // MARK: - Category List

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.sm) {
                if scanEngine.isScanning {
                    HStack {
                        ProgressView().tint(Theme.Colors.accent).scaleEffect(0.7)
                        Text("Scanning — categories update as scan completes")
                            .font(Theme.Typography.tiny)
                            .foregroundColor(Theme.Colors.textSecondary)
                        Spacer()
                    }
                    .padding(Theme.Spacing.sm)
                }

                // User-defined first
                let userCats = store.categories.filter { $0.isUserDefined }
                if !userCats.isEmpty {
                    sectionHeader("Your Categories")
                    ForEach(userCats) { cat in
                        categoryRow(cat)
                    }
                }

                // Smart categories
                sectionHeader("Smart Categories")
                LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(store.categories.filter { !$0.isUserDefined }) { cat in
                        categoryRow(cat)
                    }
                }
            }
            .padding(Theme.Spacing.md)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.headline)
            .foregroundColor(Theme.Colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Spacing.sm)
    }

    private func categoryRow(_ category: SmartCategory) -> some View {
        Button { selectedCategory = category } label: {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color(hex: category.colorHex).opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: category.icon)
                        .foregroundColor(Color(hex: category.colorHex))
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .font(Theme.Typography.headline)
                        .foregroundColor(Theme.Colors.textPrimary)
                    Text(category.isEmpty ? "Tap to scan" : "\(category.count) items")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textSecondary)
                }

                Spacer()

                if !category.isEmpty {
                    Text(sizeMBString(category))
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Theme.Colors.textTertiary)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .opacity(category.isEmpty ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private func sizeMBString(_ category: SmartCategory) -> String {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: category.assetIDs, options: nil)
        var total: Int64 = 0
        assets.enumerateObjects { asset, _, _ in
            let bytes = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            total += bytes
        }
        let mb = Double(total) / 1_048_576
        return mb > 1024 ? String(format: "%.1f GB", mb/1024) : String(format: "%.0f MB", mb)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Gradients.accent)
            Text("Run a scan to see categories")
                .font(Theme.Typography.title)
                .foregroundColor(Theme.Colors.textPrimary)
            Text("Categories appear after your first Deep Scan.\nTap + to create your own custom category.")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
    }
}

// MARK: - Category Detail View

struct CategoryDetailView: View {
    let category: SmartCategory
    @EnvironmentObject var store: CategoryStore
    @State private var selectedIDs = Set<String>()
    @State private var showingDeleteConfirm = false
    @State private var allAssets: [PHAsset] = []

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            if allAssets.isEmpty {
                Text("No items in this category")
                    .foregroundColor(Theme.Colors.textSecondary)
            } else {
                photoGrid
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !selectedIDs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete \(selectedIDs.count)") {
                        showingDeleteConfirm = true
                    }
                    .foregroundColor(Theme.Colors.danger)
                }
            }
        }
        .alert("Move to Trash?", isPresented: $showingDeleteConfirm) {
            Button("Move to Trash", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(selectedIDs.count) items to Trash. Recoverable for 30 days.")
        }
        .onAppear { loadAssets() }
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110))],
                spacing: 2
            ) {
                ForEach(allAssets, id: \.localIdentifier) { asset in
                    PhotoThumbnailView(asset: asset)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .overlay(
                            selectedIDs.contains(asset.localIdentifier)
                            ? Color.blue.opacity(0.4) : Color.clear
                        )
                        .overlay(alignment: .topTrailing) {
                            if selectedIDs.contains(asset.localIdentifier) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.white)
                                    .padding(4)
                            }
                        }
                        .onTapGesture {
                            if selectedIDs.contains(asset.localIdentifier) {
                                selectedIDs.remove(asset.localIdentifier)
                            } else {
                                selectedIDs.insert(asset.localIdentifier)
                            }
                        }
                }
            }
        }
    }

    private func loadAssets() {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: category.assetIDs, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        allAssets = assets
    }

    private func deleteSelected() {
        let toDelete = allAssets.filter { selectedIDs.contains($0.localIdentifier) } as NSArray
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(toDelete)
        }) { _, _ in
            DispatchQueue.main.async {
                allAssets.removeAll { selectedIDs.contains($0.localIdentifier) }
                selectedIDs.removeAll()
            }
        }
    }
}
