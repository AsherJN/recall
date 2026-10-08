import AVFoundation
import Foundation

/// Overwatch's voice chat. To macOS the game runs as part of this app, so the microphone
/// permission is the app's. It is asked for before Battle.net opens: left to the game, Wine
/// asks from inside Overwatch and waits for the answer, with the prompt behind a match.
/// Only the player can change it afterwards, in System Settings; Settings links there.
enum Microphone {
    enum Access { case allowed, denied, undecided }
    static var access:Access {
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: return .allowed
        case .notDetermined: return .undecided
        default: return .denied
        }
    }
    static var undecided:Bool { access == .undecided }
    /// Shows macOS's prompt; whatever the answer, later launches go straight on.
    static func ask() async { _ = await AVCaptureDevice.requestAccess(for:.audio) }
    static let privacySettings=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
