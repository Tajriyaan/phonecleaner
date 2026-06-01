import SwiftUI
import Photos
import UIKit

// MARK: - WhatsApp Clean View

struct WhatsAppView: View {
    @EnvironmentObject var scanEngine: ScanEngine
    @StateObject private var vm = WhatsAppViewModel()
    @State private var selectedGroup: MediaGroup?

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            if vm.isScanning {
                scanningOverlay
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        // App picker — only shown when both are installed
                        if vm.installedApps.count > 1 {
                            appPicker
                        }
                        storageHeader
                        openWhatsAppSection
                        if !vm.statusGroups.isEmpty   { statusSection }
                        if !vm.forwardedGroups.isEmpty { forwardedSection }
                        if vm.statusGroups.isEmpty && vm.forwardedGroups.isEmpty {
                            allCleanView
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(Theme.Spacing.md)
                }
            }
        }
        .navigationTitle("WhatsApp Clean")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $selectedGroup) { group in
            GroupDetailView(group: group)
                .environmentObject(scanEngine)
        }
        .onAppear {
            Task { @MainActor in await vm.scan() }
        }
    }

    // MARK: - App Picker

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Which WhatsApp to scan")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)

            HStack(spacing: Theme.Spacing.sm) {
                ForEach([WhatsAppApp.whatsApp, .whatsAppBusiness, .both], id: \.self) { app in
                    Button {
                        vm.selectedApp = app
                        Task { @MainActor in await vm.scan() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: app.icon)
                                .font(.system(size: 12))
                            Text(app == .both ? "Both" : app.rawValue
                                    .replacingOccurrences(of: "WhatsApp ", with: ""))
                                .font(Theme.Typography.caption)
                        }
                        .foregroundColor(vm.selectedApp == app ? .white : Theme.Colors.textSecondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(vm.selectedApp == app
                                    ? Color(hex: "#25D366")
                                    : Theme.Colors.surface)
                        .clipShape(Capsule())
                    }
                }
                Spacer()
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Storage Header

    private var storageHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2)
                .foregroundColor(Color(hex: "#25D366"))

            VStack(alignment: .leading, spacing: 2) {
                Text("WhatsApp Media")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
                Text(String(format: "%.1f MB in Photos library", vm.totalWhatsAppMB))
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)
            }
            Spacer()
            if vm.savingsMB > 0 {
                Text(String(format: "Save %.1f MB", vm.savingsMB))
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.safe)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Open WhatsApp Storage Manager

    private var openWhatsAppSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("WhatsApp Internal Storage")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)

            Text("WhatsApp's own storage manager lets you delete media from individual chats. iOS prevents any app from accessing WhatsApp's private storage directly — but we can open it for you in one tap.")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textSecondary)

            Button {
                WhatsAppAnalyzer.open(vm.selectedApp == .whatsAppBusiness ? .whatsAppBusiness : .whatsApp)
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "arrow.up.right.square.fill")
                    Text(vm.installedApps.isEmpty
                         ? "WhatsApp Not Installed"
                         : "Open \(vm.selectedApp == .both ? "WhatsApp" : vm.selectedApp.rawValue) Storage")
                        .font(Theme.Typography.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.md)
                .background(!vm.installedApps.isEmpty
                    ? Color(hex: "#25D366")
                    : Theme.Colors.textTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            }
            .disabled(vm.installedApps.isEmpty)

            if !vm.installedApps.isEmpty {
                Text("After opening WhatsApp → Settings → Storage and Data → Manage Storage")
                    .font(Theme.Typography.tiny)
                    .foregroundColor(Theme.Colors.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Status Saves

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader(
                title: "Status Saves",
                subtitle: "\(vm.statusGroups.flatMap(\.assets).count) items · \(String(format: "%.1f MB", vm.statusSavingsMB))",
                icon: "circle.fill",
                color: Color(hex: "#25D366")
            )
            ForEach(vm.statusGroups) { group in
                groupRow(group: group)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Forwarded Duplicates

    private var forwardedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader(
                title: "Forwarded Duplicates",
                subtitle: "\(vm.forwardedGroups.count) groups · \(String(format: "%.1f MB", vm.forwardedSavingsMB))",
                icon: "arrow.triangle.2.circlepath",
                color: Theme.Colors.review
            )
            Text("Same image saved multiple times from different chats. Best copy kept automatically — at least 1 always preserved.")
                .font(Theme.Typography.tiny)
                .foregroundColor(Theme.Colors.textTertiary)

            ForEach(vm.forwardedGroups) { group in
                groupRow(group: group)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Shared Components

    private func sectionHeader(title: String, subtitle: String,
                                icon: String, color: Color) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 10))
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)
            Spacer()
            Text(subtitle)
                .font(Theme.Typography.tiny)
                .foregroundColor(Theme.Colors.textSecondary)
        }
    }

    private func groupRow(group: MediaGroup) -> some View {
        Button { selectedGroup = group } label: {
            HStack(spacing: Theme.Spacing.md) {
                if let first = group.assets.first {
                    PhotoThumbnailView(asset: first.phAsset)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(Theme.Typography.headline)
                        .foregroundColor(Theme.Colors.textPrimary)
                    Text("\(group.assets.count) items · keeping \(group.assets.count - group.selectedForDeletion.count)")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textSecondary)
                    Text(String(format: "%.1f MB can be freed", group.estimatedSizeMB))
                        .font(Theme.Typography.tiny)
                        .foregroundColor(Theme.Colors.safe)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Theme.Colors.textTertiary)
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    private var scanningOverlay: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .tint(Color(hex: "#25D366"))
                .scaleEffect(1.5)
            Text(vm.scanStatus)
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)
        }
    }

    private var allCleanView: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(Color(hex: "#25D366"))
            Text("WhatsApp Photos All Clean")
                .font(Theme.Typography.title)
                .foregroundColor(Theme.Colors.textPrimary)
            Text("No duplicate forwards or Status saves found.")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
    }
}

// MARK: - WhatsApp ViewModel
// No @MainActor here — @StateObject in SwiftUI already runs on MainActor.
// Published property updates from async context go via MainActor.run.

final class WhatsAppViewModel: ObservableObject {
    @Published var statusGroups: [MediaGroup]    = []
    @Published var forwardedGroups: [MediaGroup] = []
    @Published var isScanning = false
    @Published var scanStatus = "Scanning…"
    @Published var totalWhatsAppMB: Double = 0
    @Published var installedApps: [WhatsAppApp] = []
    @Published var selectedApp: WhatsAppApp = .both

    private let analyzer = WhatsAppAnalyzer()

    var savingsMB: Double          { statusSavingsMB + forwardedSavingsMB }
    var statusSavingsMB: Double    { statusGroups.reduce(0)   { $0 + $1.estimatedSizeMB } }
    var forwardedSavingsMB: Double { forwardedGroups.reduce(0) { $0 + $1.estimatedSizeMB } }

    func checkInstalledApps() async {
        let apps = await MainActor.run { WhatsAppAnalyzer.installedApps() }
        await MainActor.run {
            installedApps = apps
            // Default to Both if both installed, otherwise whichever is present
            // Prefer regular WhatsApp as the default single-app selection
            if apps.count > 1 {
                selectedApp = .both
            } else if apps.contains(.whatsApp) {
                selectedApp = .whatsApp
            } else if apps.contains(.whatsAppBusiness) {
                selectedApp = .whatsAppBusiness
            }
        }
    }

    func scan() async {
        await MainActor.run { isScanning = true; statusGroups = []; forwardedGroups = [] }

        await checkInstalledApps()

        await MainActor.run { scanStatus = "Loading \(selectedApp.rawValue) media…" }
        let allAssets = await analyzer.allAssets(for: selectedApp)
        let totalMB   = await analyzer.storageMB(for: selectedApp)
        await MainActor.run { totalWhatsAppMB = totalMB }

        // Status saves
        await MainActor.run { scanStatus = "Detecting Status saves…" }
        let statusAssets = await analyzer.statusSaves(from: allAssets)
        if !statusAssets.isEmpty {
            let mediaAssets = statusAssets.map { MediaAsset(phAsset: $0) }
            let group = MediaGroup(
                groupType: .whatsApp(.statusSave),
                assets: mediaAssets,
                confidence: .reviewRecommended,
                estimatedSizeMB: sizeMB(statusAssets)
            )
            // Pre-select all non-favourites for deletion; MediaGroup.init already
            // guarantees at least 1 is kept via its safety check.
            await MainActor.run { statusGroups = [group] }
        }

        // Forwarded duplicates
        await MainActor.run { scanStatus = "Finding forwarded duplicates…" }
        let duplicateClusters = await analyzer.forwardedDuplicateGroups(from: allAssets)
        let fGroups: [MediaGroup] = duplicateClusters.map { cluster in
            let mediaAssets = cluster.map { MediaAsset(phAsset: $0) }
            return MediaGroup(
                groupType: .whatsApp(.forwardedDuplicate),
                assets: mediaAssets,
                confidence: .safeToDelete,
                estimatedSizeMB: sizeMB(cluster)
            )
            // MediaGroup.init keeps the best quality asset, safety check keeps at least 1
        }
        await MainActor.run {
            forwardedGroups = fGroups
            isScanning = false
        }
    }

    private func sizeMB(_ assets: [PHAsset]) -> Double {
        assets.reduce(0.0) { acc, a in
            let bytes = PHAssetResource.assetResources(for: a)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return acc + Double(bytes) / 1_048_576
        }
    }
}
