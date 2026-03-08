import SwiftUI
import Photos

/// Asynchronously loads a Photos thumbnail and displays it.
struct ThumbnailImage: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video.fill")
                    .foregroundColor(.secondary)
            }
        }
        .clipped()
        .task(id: asset.localIdentifier) {
            await load()
        }
    }

    private func load() async {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat       // fires callback exactly once → safe with continuation
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false
        image = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                cont.resume(returning: img)
            }
        }
    }
}
