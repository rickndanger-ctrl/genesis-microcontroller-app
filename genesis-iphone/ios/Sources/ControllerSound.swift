import AudioToolbox
import Foundation

@MainActor
final class ControllerSound {
    static let shared = ControllerSound()

    private lazy var tick = load("DialTick")
    private lazy var click = load("KeyClick")

    func dialTick() {
        guard enabled else { return }
        if let tick { AudioServicesPlaySystemSound(tick) }
    }

    func keyClick() {
        guard enabled else { return }
        if let click { AudioServicesPlaySystemSound(click) }
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "controllerSoundsEnabled") as? Bool ?? true
    }

    private func load(_ name: String) -> SystemSoundID? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError ? id : nil
    }
}
