import Foundation

class PINManager {
    // Exclude visually confusing chars (0/O, 1/I/L)
    private let characters = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private(set) var currentPIN: String = ""

    init() {
        generateNewPIN()
    }

    func generateNewPIN() {
        currentPIN = String((0..<4).map { _ in characters.randomElement()! })
    }

    /// Case-insensitive PIN verification
    func verify(_ pin: String) -> Bool {
        return pin.uppercased() == currentPIN
    }
}
