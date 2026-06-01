import SwiftUI
import Photos
import UIKit

struct DashboardView: View {
    @EnvironmentObject var scanEngine: ScanEngine
    @State private var showingScanView = false
    @State private var showingReview = false
    @State private var deviceStorage: (used: Double, total: Double) = (0, 0)
    @State private var permissionError: String?
    @State private var showingPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {

                        // Header
                        headerSection

                        // Storage ring
                        storageRingSection

                        // Quick stats if scan done
                        if let result = scanEngine.result {
                            scanSummarySection(result: result)
                            categoryCardsSection(result: result)

                            // Review button
                            reviewButton
                                .onTapGesture { showingReview = true }
                        } else {
                            // Scan prompt
                            scanPromptSection
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { loadDeviceStorage(); checkPhotoPermission() }
            .alert("Photos Access Required", isPresented: $showingPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(permissionError ?? "Please allow Full Access to Photos in Settings → Privacy & Security → Photos → DeepClean")
            }
            .sheet(isPresented: $showingScanView) {
                ScanProgressView()
                    .environmentObject(scanEngine)
            }
            .navigationDestination(isPresented: $showingReview) {
                ReviewView()
                    .environmentObject(scanEngine)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DeepClean")
                    .font(Theme.Typography.largeTitle)
                    .foregroundStyle(Theme.Gradients.accent)
                Text("AI-Powered Phone Cleaner")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textTertiary)
            }
            Spacer()
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Theme.Gradients.accent)
        }
        .padding(.top, Theme.Spacing.md)
    }

    // MARK: - Storage Ring

    private var storageRingSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            StorageRingView(
                usedGB: deviceStorage.used,
                totalGB: deviceStorage.total,
                savingsGB: scanEngine.result?.totalSavingsGB ?? 0,
                animated: true
            )

            HStack(spacing: Theme.Spacing.xl) {
                StorageCategoryBar(label: "Photos", usedGB: 0, color: Theme.Colors.accent)
                StorageCategoryBar(label: "Videos", usedGB: 0, color: Theme.Colors.accentSecondary)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    // MARK: - Scan Summary

    private func scanSummarySection(result: ScanResult) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            statCard(
                value: result.totalDuplicateGroups,
                label: "Duplicate Groups",
                color: Theme.Colors.danger
            )
            statCard(
                value: result.totalJunkItems,
                label: "Junk Items",
                color: Theme.Colors.review
            )
            statCard(
                value: String(format: "%.1f GB", result.totalSavingsGB),
                label: "Can Save",
                color: Theme.Colors.safe
            )
        }
    }

    private func statCard(value: any CustomStringConvertible, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value.description)
                .font(Theme.Typography.title)
                .foregroundColor(color)
            Text(label)
                .font(Theme.Typography.tiny)
                .foregroundColor(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Category Cards

    private func categoryCardsSection(result: ScanResult) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text("What We Found")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(result.groups.prefix(6)) { group in
                categoryCard(group: group)
            }
        }
    }

    private func categoryCard(group: MediaGroup) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: 4)
                .fill(group.confidence.themeColor)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
                Text("\(group.assets.count) items · \(String(format: "%.1f", group.estimatedSizeMB)) MB")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)
            }
            Spacer()

            Text(group.confidence.label)
                .font(Theme.Typography.tiny)
                .foregroundColor(group.confidence.themeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(group.confidence.themeColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Scan Prompt

    private var scanPromptSection: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Gradients.accent)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Ready to Deep Clean")
                    .font(Theme.Typography.title)
                    .foregroundColor(Theme.Colors.textPrimary)
                Text("AI scans your entire photo library, WhatsApp media, and videos to find duplicates, junk shots, and more.")
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            scanButton
        }
        .padding(Theme.Spacing.xl)
    }

    private func checkPhotoPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .denied || status == .restricted {
            permissionError = "DeepClean needs Full Access to Photos. Go to Settings → Privacy & Security → Photos → DeepClean → Full Access."
            showingPermissionAlert = true
        }
    }

    private var scanButton: some View {
        Button {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .denied || status == .restricted {
                permissionError = "Please allow Full Access to Photos in Settings → Privacy & Security → Photos → DeepClean."
                showingPermissionAlert = true
                return
            }
            showingScanView = true
            scanEngine.startScan()
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "sparkles")
                Text("Start Deep Scan")
                    .font(Theme.Typography.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.md)
            .background(Theme.Gradients.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
    }

    private var reviewButton: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
            Text("Review & Clean")
                .font(Theme.Typography.headline)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.md)
        .background(Theme.Gradients.accent)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    // MARK: - Storage

    private func loadDeviceStorage() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            let total = (attrs[.systemSize] as? Int64 ?? 0)
            let free  = (attrs[.systemFreeSize] as? Int64 ?? 0)
            deviceStorage = (
                used:  Double(total - free) / 1_073_741_824,
                total: Double(total) / 1_073_741_824
            )
        }
    }
}
