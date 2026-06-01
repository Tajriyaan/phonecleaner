import SwiftUI
import Photos

// MARK: - Photo Thumbnail
// Async image loader backed by PHImageManager.

struct PhotoThumbnailView: View {
    let asset: PHAsset
    var targetSize: CGSize = CGSize(width: 300, height: 300)

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Theme.Colors.surfaceElevated)
                    .overlay(
                        ProgressView().tint(Theme.Colors.textTertiary)
                    )
            }
        }
        .task(id: asset.localIdentifier) {
            image = await load()
        }
    }

    private func load() async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize,
                contentMode: .aspectFill, options: options
            ) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.resume(returning: img) }
            }
        }
    }
}
