import Foundation

struct TransferItem: Identifiable {
    let id: String
    let filename: String
    let totalBytes: Int64
    var transferredBytes: Int64 = 0
    var isCompleted: Bool = false
    var isCurrent: Bool = false

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }
}
