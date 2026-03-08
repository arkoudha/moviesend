import Foundation
import SwiftUI

@MainActor
final class URLPINViewModel: ObservableObject {
    @Published var localIP: String = ""
    @Published var mdnsURL: String = ""
    @Published var pin: String = ""
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

        do {
            try server.start()
            isServerRunning = true
            pin = pinManager.currentPIN
            localIP  = NetworkInfoService.getLocalIPAddress() ?? ""
            mdnsURL  = "http://\(NetworkInfoService.getLocalHostname()):8080/"
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
