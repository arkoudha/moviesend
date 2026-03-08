import Foundation
import Photos
import AVFoundation
import UIKit

enum PhotosError: Error {
    case assetNotAvailable
    case unauthorized
}

enum PhotosService {
    static func requestAuthorization() async -> PHAuthorizationStatus {
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func fetchVideos() async -> [VideoAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let results = PHAsset.fetchAssets(with: options)

        // Collect assets synchronously first, then process concurrently
        var assets: [(Int, PHAsset)] = []
        results.enumerateObjects { asset, index, _ in
            assets.append((index, asset))
        }

        var videos: [VideoAsset] = []
        await withTaskGroup(of: (Int, VideoAsset?).self) { group in
            for (index, asset) in assets {
                group.addTask { (index, await makeVideoAsset(from: asset)) }
            }
            var indexed: [(Int, VideoAsset)] = []
            for await (idx, video) in group {
                if let v = video { indexed.append((idx, v)) }
            }
            videos = indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
        return videos
    }

    private static func makeVideoAsset(from asset: PHAsset) async -> VideoAsset? {
        let resources = PHAssetResource.assetResources(for: asset)
        let videoResource = resources.first(where: { $0.type == .video })
        let filename = videoResource?.originalFilename ?? "video.mov"
        let size = videoResource.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0

        // Get codec from AVAsset
        let codec = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .fastFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                var detectedCodec = "H.264"
                if let urlAsset = avAsset as? AVURLAsset,
                   let track = urlAsset.tracks(withMediaType: .video).first,
                   let desc = track.formatDescriptions.first {
                    let sub = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
                    if sub == kCMVideoCodecType_HEVC { detectedCodec = "HEVC" }
                }
                continuation.resume(returning: detectedCodec)
            }
        }

        return VideoAsset(
            id: asset.localIdentifier,
            filename: filename,
            duration: asset.duration,
            size: size,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            createdAt: asset.creationDate ?? Date(),
            codec: codec,
            phAsset: asset
        )
    }

    /// Returns AVURLAsset for a given PHAsset (throws if iCloud-only)
    static func getAVURLAsset(for asset: PHAsset) async throws -> AVURLAsset {
        return try await withCheckedThrowingContinuation { continuation in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, info in
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotosError.assetNotAvailable)
                }
            }
        }
    }

    /// Generates JPEG thumbnail data for a PHAsset
    static func getThumbnail(for asset: PHAsset, size: CGSize = CGSize(width: 120, height: 120)) async -> Data? {
        return await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: size,
                contentMode: .aspectFill, options: opts
            ) { image, _ in
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.7))
            }
        }
    }
}
