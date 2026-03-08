import Foundation
import SwiftUI

@MainActor
final class URLPINViewModel: ObservableObject {
    @Published var localIP: String = ""
    @Published var mdnsURL: String = ""
    @Published var pin: String = ""
    /// True only after NWListener confirms .ready — not just after start() is called
    @Published var isServerRunning = false
    @Published var isClientConnected = false
    @Published var errorMessage: String?

    let sessionManager = SessionManager()
    let pinManager     = PINManager()

    private var httpServer: HTTPServer?
    private(set) var router: Router?

    func startServer(with videos: [VideoAsset]) {
        let router = Router(sessionManager: sessionManager, pinManager: pinManager)
        router.updateVideoCache(videos)
        router.onAuthenticated = { [weak self] in
            self?.isClientConnected = true
        }
        self.router = router

        let server = HTTPServer(router: router)
        httpServer = server

        // Pre-fill PIN and URLs immediately so the UI isn't blank while the
        // listener is starting up (usually < 100 ms).
        pin     = pinManager.currentPIN
        localIP = NetworkInfoService.getLocalIPAddress() ?? ""
        mdnsURL = "http://\(NetworkInfoService.getLocalHostname()):8080/"

        do {
            try server.start(
                onReady: { [weak self] actualPort in
                    // Called on a background queue — dispatch to main
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isServerRunning = true
                        // Update port in URLs in case OS picked a different one
                        self.mdnsURL = "http://\(NetworkInfoService.getLocalHostname()):\(actualPort)/"
                        if !self.localIP.isEmpty {
                            // localIP already set; just keep it
                        }
                    }
                },
                onError: { [weak self] error in
                    DispatchQueue.main.async {
                        self?.errorMessage = "サーバーの起動に失敗しました: \(error.localizedDescription)"
                        self?.isServerRunning = false
                    }
                }
            )
        } catch {
            errorMessage = "サーバーの起動に失敗しました: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        httpServer?.stop()
        isServerRunning = false
        isClientConnected = false
    }
}
