import SwiftUI

struct VideoRowView: View {
    let video: VideoAsset
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            // Thumbnail (async from Photos)
            ThumbnailImage(asset: video.phAsset)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(video.filename)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(formatDuration(video.duration))
                    Text("·")
                    Text(formatSize(video.size))
                    Text("·")
                    Text("\(video.width)×\(video.height)")
                }
                .font(.caption).foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private func formatDuration(_ s: Double) -> String {
        let t = Int(s)
        return t < 60 ? "\(t)秒" : "\(t / 60)分\(t % 60)秒"
    }

    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        return mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1000)
    }
}
