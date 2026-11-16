import Foundation

@main
struct ControllerSoundTests {
    @MainActor static func main() {
        let suite = "genesis-controller-sound-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        var events: [ControllerSound.Event] = []
        var applicationActive = true
        let sound = ControllerSound(preferences: preferences, applicationIsActive: { applicationActive }, playback: { events.append($0) })
        check(events.isEmpty, "Creating a controller never plays a sound")
        check(preferences.object(forKey: ControllerSound.preferenceKey) == nil, "Default-on does not overwrite the stored choice")
        sound.keyClick(); sound.dialTick()
        check(events == [.key, .detent], "An explicit key and detent each produce their own event once")

        preferences.set(false, forKey: ControllerSound.preferenceKey)
        sound.keyClick(); sound.dialTick()
        check(events == [.key, .detent], "Sound-off takes effect for both event types immediately")
        let reopened = ControllerSound(preferences: preferences, playback: { events.append($0) })
        reopened.keyClick(); reopened.dialTick()
        check(events.count == 2, "A reopened controller honors the saved sound-off preference")
        preferences.set(true, forKey: ControllerSound.preferenceKey)
        check(events.count == 2, "Restoring a setting never schedules a sound by itself")
        reopened.keyClick()
        check(events == [.key, .detent, .key], "A later intentional tap uses the current enabled setting")

        enum CapturePhase { case idle, authorizing, recording, finalizing }
        var phase = CapturePhase.idle
        sound.captureIsActive = { phase != .idle }
        for active in [CapturePhase.authorizing, .recording, .finalizing] {
            phase = active
            sound.keyClick(); sound.dialTick()
            check(events.count == 3, "Every capture stage suppresses key and detent playback")
        }
        phase = .idle
        check(events.count == 3, "Ending capture does not replay any suppressed event")
        sound.dialTick()
        check(events == [.key, .detent, .key, .detent], "A new intentional detent can sound after capture finishes")
        phase = .recording
        preferences.set(false, forKey: ControllerSound.preferenceKey)
        phase = .idle
        sound.keyClick()
        check(events.count == 4, "Finishing recording never overrides the user's mute preference")
        preferences.set(true, forKey: ControllerSound.preferenceKey)
        for _ in 0..<4 { sound.dialTick() }
        for _ in 0..<3 { sound.keyClick() }
        check(events.count == 11, "Separate rapid accepted interactions are not collapsed or doubled")
        check(Array(events.suffix(7)) == [.detent, .detent, .detent, .detent, .key, .key, .key], "Rapid clicks retain their sound identities and order")
        applicationActive = false
        sound.keyClick(); sound.dialTick()
        check(events.count == 11, "Late release feedback is silent after app background or lock")
        applicationActive = true
        check(events.count == 11, "Foreground return does not replay sounds from background")
        sound.keyClick()
        check(events.count == 12 && events.last == .key, "A fresh foreground tap can sound normally")
        print("Controller sound: \(checks) checks passed (injected playback; no audio played)")
    }
}
