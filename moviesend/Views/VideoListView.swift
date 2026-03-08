import SwiftUI
import Photos

struct VideoListView: View {
    @StateObject private var vm = VideoListViewModel()
    @State private var navigateToPIN = false

    var body: some View {
        NavigationStack {
            Group {
                switch vm.authorizationStatus {
                case .authorized, .limited:
                    listContent
                case .denied, .restricted:
                    permissionDeniedView
                default:
                    ProgressView("フォトライブラリを確認中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("MovieSend")
            .navigationDestination(isPresented: $navigateToPIN) {
                URLPINView(selectedVideos: vm.selectedVideos)
            }
        }
        .task { await vm.checkAndRequestAuthorization() }
    }

    // MARK: - List content

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            if vm.isLoading {
                ProgressView("動画を読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videos.isEmpty {
                emptyVideosView
            } else {
                List(vm.videos) { video in
                    VideoRowView(
                        video: video,
                        isSelected: vm.selectedIDs.contains(video.id),
                        onToggle: { vm.toggleSelection(video.id) }
                    )
                }
                .listStyle(.plain)
            }

            if !vm.videos.isEmpty {
                bottomBar
            }
        }
        .toolbar(content: {
            ToolbarItem(placement: .topBarTrailing) {
                Button(vm.selectedIDs.count == vm.videos.count ? "選択解除" : "全て選択") {
                    if vm.selectedIDs.count == vm.videos.count { vm.clearSelection() }
                    else { vm.selectAll() }
                }
            }
        })
    }

    // MARK: - Empty state

    private var emptyVideosView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("動画がありません")
                .font(.title3).fontWeight(.semibold)
            Text("フォトライブラリに動画が見つかりませんでした")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if vm.selectedIDs.isEmpty {
                    Text("動画を選択してください")
                        .foregroundColor(.secondary).font(.subheadline)
                } else {
                    Text("\(vm.selectedIDs.count)件 / \(formatSize(vm.totalSelectedSize))")
                        .font(.subheadline).fontWeight(.medium)
                }
                Spacer()
                Button("転送開始") { navigateToPIN = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.selectedIDs.isEmpty)
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: - Permission denied

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("フォトライブラリへのアクセスが必要です")
                .font(.title3).fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text("設定アプリから MovieSend のフォトライブラリアクセスを許可してください")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        return mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1000)
    }
}
