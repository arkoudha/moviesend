import SwiftUI

struct URLPINView: View {
    let selectedVideos: [VideoAsset]
    @StateObject private var vm = URLPINViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var navigateToProgress = false
    /// true while TransferProgressView is on the stack — prevents onDisappear
    /// from stopping the server when navigating FORWARD (which is the root
    /// cause of ERR_CONNECTION_REFUSED during download).
    @State private var navigatingToProgress = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                VStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 52))
                        .foregroundColor(vm.isServerRunning ? .blue : .secondary)
                    Text(vm.isServerRunning ? "PCで接続してください" : "サーバーを起動中…")
                        .font(.title2).fontWeight(.bold)
                        .foregroundColor(vm.isServerRunning ? .primary : .secondary)
                }

                if vm.isServerRunning {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("ブラウザでアクセス", systemImage: "safari")
                            .font(.subheadline).foregroundColor(.secondary)
                        if !vm.mdnsURL.isEmpty { urlRow(vm.mdnsURL, tag: "mDNS") }
                        if !vm.localIP.isEmpty { urlRow("http://\(vm.localIP):8080/", tag: "IP直接") }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))

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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    ProgressView()
                        .scaleEffect(1.4)
                        .padding(.vertical, 40)
                }

                Group {
                    if vm.isClientConnected {
                        Label("接続済み", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if vm.isServerRunning {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("接続待機中…")
                        }
                        .foregroundColor(.secondary)
                    } else {
                        Text("ローカルネットワーク許可が必要な場合はダイアログで「OK」を選んでください")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .font(.subheadline)

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
            .animation(.easeOut(duration: 0.3), value: vm.isServerRunning)
        }
        .navigationTitle(vm.isServerRunning ? "接続待機中" : "起動中")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.isServerRunning)
        .navigationDestination(isPresented: $navigateToProgress) {
            TransferProgressView(selectedVideos: selectedVideos, onFinish: {
                // Called when transfer is done or cancelled from TransferProgressView.
                // Stop server and pop both TransferProgressView and URLPINView.
                navigatingToProgress = false
                navigateToProgress   = false
                vm.stopServer()
                dismiss()
            })
        }
        .onAppear { vm.startServer(with: selectedVideos) }
        .onDisappear {
            // Only stop server when truly leaving (back/cancel), NOT when pushing
            // TransferProgressView forward — that caused ERR_CONNECTION_REFUSED.
            if !navigatingToProgress { vm.stopServer() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { vm.stopServer() }
        }
        .onChange(of: vm.isClientConnected) { connected in
            if connected {
                navigatingToProgress = true
                navigateToProgress   = true
            }
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
