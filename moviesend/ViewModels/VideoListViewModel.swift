import Foundation
import Photos
import SwiftUI

@MainActor
final class VideoListViewModel: ObservableObject {
    @Published var videos: [VideoAsset] = []
    @Published var selectedIDs: Set<String> = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading = false

    var selectedVideos: [VideoAsset] { videos.filter { selectedIDs.contains($0.id) } }

    var totalSelectedSize: Int64 { selectedVideos.reduce(0) { $0 + $1.size } }

    func checkAndRequestAuthorization() async {
        authorizationStatus = await PhotosService.requestAuthorization()
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            await loadVideos()
        }
    }

    func loadVideos() async {
        isLoading = true
        videos = await PhotosService.fetchVideos()
        isLoading = false
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    func selectAll()    { selectedIDs = Set(videos.map { $0.id }) }
    func clearSelection() { selectedIDs.removeAll() }
}
