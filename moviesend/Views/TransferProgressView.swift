import SwiftUI

struct TransferProgressView: View {
    let selectedVideos: [VideoAsset]
    @StateObject private var vm = TransferViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.isAllCompleted {
                completionView
            } else {
                progressList
            }
        }
        .navigationTitle("転送進捗")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(content: {
            ToolbarItem(placement: .topBarTrailing) {
                if !vm.isAllCompleted {
                    Button("中断") { showCancelConfirm = true }
                        .foregroundColor(.red)
                }
            }
        })
        .confirmationDialog("転送を中断しますか？", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("中断する", role: .destructive) {
                dismiss()
            }
            Button("続ける", role: .cancel) { }
        }
        .onAppear { vm.setup(with: selectedVideos) }
    }

    // MARK: - Progress list

    private var progressList: some View {
        VStack(spacing: 0) {
            List(vm.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.filename)
                            .font(.subheadline).fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                        if item.isCompleted {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        } else if item.isCurrent {
                            Text("\(Int(item.progress * 100))%")
                                .font(.caption).foregroundColor(.blue)
                        } else {
                            Text("待機中").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if item.isCurrent || item.isCompleted {
                        ProgressBarView(progress: item.isCompleted ? 1.0 : item.progress,
                                       color: item.isCompleted ? .green : .blue)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)

            // ブラウザ側でキャンセルされた場合などに戻れるよう常時表示
            Divider()
            Button("中断して戻る") { showCancelConfirm = true }
                .foregroundColor(.red)
                .padding()
        }
    }

    // MARK: - Completion view

    private var completionView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)
            Text("転送完了").font(.title).fontWeight(.bold)
            Text("\(vm.totalFiles)ファイル / \(formatSize(vm.totalSize)) を転送しました")
                .foregroundColor(.secondary)
            Spacer()
            Button("最初に戻る") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
        }
        .padding()
    }

    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        return mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1000)
    }
}
