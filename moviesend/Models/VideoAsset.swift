import Foundation
import Photos

struct VideoAsset: Identifiable {
    let id: String
    let filename: String
    let duration: Double
    let size: Int64
    let width: Int
    let height: Int
    let createdAt: Date
    let codec: String
    let phAsset: PHAsset

    func toDictionary() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": id,
            "filename": filename,
            "duration": duration,
            "size": size,
            "width": width,
            "height": height,
            "createdAt": formatter.string(from: createdAt),
            "mediaType": "video",
            "codec": codec
        ]
    }
}
