import Foundation

class SessionManager {
    private(set) var token: String = ""
    private(set) var expiry: Date = Date()
    private let sessionDuration: TimeInterval = 30 * 60 // 30 minutes

    init() {
        createNewSession()
    }

    func createNewSession() {
        token = UUID().uuidString
        expiry = Date().addingTimeInterval(sessionDuration)
    }

    /// Constant-time comparison to prevent timing attacks
    func validate(token: String) -> Bool {
        guard Date() < expiry else { return false }
        guard token.count == self.token.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(token.utf8, self.token.utf8) {
            result |= a ^ b
        }
        return result == 0
    }

    var isExpired: Bool { Date() >= expiry }
}
