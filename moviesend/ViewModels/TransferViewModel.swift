import Foundation
import SwiftUI

@MainActor
final class TransferViewModel: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published var isAllCompleted = false
    @Published var transferSpeedBps: Double = 0

    var completedCount: Int { items.filter { $0.isCompleted }.count }
    var totalFiles: Int    { items.count }
    var totalSize: Int64   { items.reduce(0) { $0 + $1.totalBytes } }

    func setup(with videos: [VideoAsset]) {
        items = videos.map { TransferItem(id: $0.id, filename: $0.filename, totalBytes: $0.size) }
        if !items.isEmpty { items[0].isCurrent = true }
    }

    func markCompleted(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].isCompleted = true
            items[idx].isCurrent  = false
            // Activate next
            if idx + 1 < items.count { items[idx + 1].isCurrent = true }
            else { isAllCompleted = true }
        }
    }
}
