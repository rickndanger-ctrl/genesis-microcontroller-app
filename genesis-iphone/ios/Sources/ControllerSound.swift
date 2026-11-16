import AudioToolbox
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ControllerSound {
    static let shared = ControllerSound()
    static let preferenceKey = "controllerSoundsEnabled"

    enum Event: Equatable { case key, detent }
    // Read the store's current authorizing/recording/finalizing state at the
    // actual tap, including actions in sheets. Never queue a suppressed sound.
    var captureIsActive: @MainActor () -> Bool
    private let preferences: UserDefaults
    private let applicationIsActive: @MainActor () -> Bool
    private let playback: ((Event) -> Void)?

    init(preferences: UserDefaults = .standard,
         captureIsActive: @escaping @MainActor () -> Bool = { false },
         applicationIsActive: @escaping @MainActor () -> Bool = {
             #if canImport(UIKit)
             return UIApplication.shared.applicationState == .active
             #else
             return true
             #endif
         },
         playback: ((Event) -> Void)? = nil) {
        self.preferences = preferences
        self.captureIsActive = captureIsActive
        self.applicationIsActive = applicationIsActive
        self.playback = playback
    }

    private lazy var tick = load("DialTick")
    private lazy var click = load("KeyClick")

    func dialTick() {
        play(.detent)
    }

    func keyClick() {
        play(.key)
    }

    private func play(_ event: Event) {
        guard enabled, applicationIsActive(), !captureIsActive() else { return }
        if let playback { playback(event); return }
        let sound = event == .key ? click : tick
        // System UI sounds retain the user's system volume/silent behavior.
        // Do not activate or reconfigure the dictation audio session.
        if let sound { AudioServicesPlaySystemSound(sound) }
    }

    private var enabled: Bool {
        preferences.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    private func load(_ name: String) -> SystemSoundID? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError ? id : nil
    }
}
