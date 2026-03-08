import SwiftUI

struct URLPINView: View {
    let selectedVideos: [VideoAsset]
    @StateObject private var vm = URLPINViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var navigateToProgress = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                // Icon + title
                VStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 52))
                        .foregroundColor(.blue)
                    Text("PCで接続してください")
                        .font(.title2).fontWeight(.bold)
                }

                // URL card
                VStack(alignment: .leading, spacing: 10) {
                    Label("ブラウザでアクセス", systemImage: "safari")
                        .font(.subheadline).foregroundColor(.secondary)
                    urlRow("http://moviesend.local:8080/", tag: "mDNS")
                    if !vm.localIP.isEmpty {
                        urlRow("http://\(vm.localIP):8080/", tag: "IP直接")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                // PIN card
                VStack(spacing: 10) {
                    Text("PIN コード")
                        .font(.subheadline).foregroundColor(.secondary)
                    Text(vm.pin)
                        .font(.system(size: 60, weight: .bold, design: .monospaced))
                        .tracking(12)
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Status
                Group {
                    if vm.isClientConnected {
                        Label("接続済み", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("接続待機中…")
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .font(.subheadline)

                // File count
                Text("\(selectedVideos.count)件の動画を転送します")
                    .font(.caption).foregroundColor(.secondary)

                Spacer(minLength: 20)

                Button("キャンセル") {
                    vm.stopServer()
                    dismiss()
                }
                .foregroundColor(.red)
                .padding(.bottom)
            }
            .padding()
        }
        .navigationTitle("接続待機中")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.isServerRunning)
        .navigationDestination(isPresented: $navigateToProgress) {
            TransferProgressView(selectedVideos: selectedVideos)
        }
        .onAppear { vm.startServer(with: selectedVideos) }
        .onDisappear { vm.stopServer() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { vm.stopServer() }
        }
        .onChange(of: vm.isClientConnected) { connected in
            if connected { navigateToProgress = true }
        }
        .alert("エラー", isPresented: .init(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { dismiss() }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private func urlRow(_ url: String, tag: String) -> some View {
        HStack {
            Text(url)
                .font(.system(.body, design: .monospaced)).fontWeight(.medium)
            Spacer()
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .clipShape(Capsule())
        }
    }
}
