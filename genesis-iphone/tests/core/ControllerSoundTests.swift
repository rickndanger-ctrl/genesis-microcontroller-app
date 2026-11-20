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

        // Click pack and volume preferences.
        check(sound.pack.id == "crunch" && preferences.object(forKey: ControllerSound.packKey) == nil, "Crunch is the default pack and reading it stores nothing")
        check(sound.volume == 1 && preferences.object(forKey: ControllerSound.volumeKey) == nil, "Volume defaults to full without storing a choice")
        check(Set(ControllerSound.packs.map(\.id)).count == ControllerSound.packs.count, "Pack identifiers are unique")
        preferences.set("thock", forKey: ControllerSound.packKey)
        check(sound.pack.id == "thock" && reopened.pack.id == "thock", "A saved pack applies to every controller at once")
        preferences.set("retired-pack", forKey: ControllerSound.packKey)
        check(sound.pack == ControllerSound.defaultPack, "An unknown saved pack falls back instead of going silent")
        preferences.set(0.52, forKey: ControllerSound.volumeKey)
        check(abs(sound.volume - 0.50) < 0.0001, "Volume snaps to the control's steps")
        preferences.set(7.0, forKey: ControllerSound.volumeKey)
        check(sound.volume == 1, "Volume clamps at full")
        preferences.set(-3.0, forKey: ControllerSound.volumeKey)
        check(sound.volume == 0, "Volume clamps at zero")
        let beforeSilent = events.count
        sound.keyClick(); sound.dialTick()
        check(events.count == beforeSilent, "Zero volume plays nothing")
        preferences.set(0.4, forKey: ControllerSound.volumeKey)
        check(events.count == beforeSilent, "Raising the volume never plays a sound by itself")
        sound.keyClick()
        check(events.count == beforeSilent + 1 && events.last == .key, "A tap sounds again once the volume is above zero")
        check(ControllerSound.gain(forVolume: 1) == 1 && ControllerSound.gain(forVolume: 0) == 0, "Gain spans silence to unity")
        check(ControllerSound.gain(forVolume: 0.5) < 0.5 && ControllerSound.gain(forVolume: 0.5) > 0, "The gain curve is gentler than linear at the low end")
        check(ControllerSound.gain(forVolume: 4) == 1, "Gain never boosts past unity")

        // Scaled copies for volumes below full.
        func wav(samples: [Int16], format: UInt16 = 1, bits: UInt16 = 16, extraChunk: Bool = false) -> Data {
            var data = Data()
            func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            let extra = extraChunk ? 12 : 0
            data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + extra + samples.count * 2)); data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8)); put(16); put16(format); put16(1); put(44100); put(88200); put16(2); put16(bits)
            if extraChunk { data.append(contentsOf: Array("LIST".utf8)); put(3); data.append(contentsOf: [1, 2, 3, 0]) }
            data.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2))
            samples.forEach { put16(UInt16(bitPattern: $0)) }
            return data
        }
        func samples(_ data: Data, at offset: Int = 44) -> [Int16] {
            let bytes = [UInt8](data)
            return stride(from: offset, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
        }
        let source = wav(samples: [0, 1000, -1000, 32767, -32768, 3])
        let half = ControllerSound.scaledWAV(source, gain: 0.5)
        check(half != nil && samples(half!) == [0, 500, -500, 16384, -16384, 2], "Half gain halves every sample, rounding to nearest")
        check(half!.prefix(44) == source.prefix(44), "Scaling leaves the header untouched")
        check(samples(ControllerSound.scaledWAV(source, gain: 0)!) == [0, 0, 0, 0, 0, 0], "Zero gain is silence")
        check(samples(ControllerSound.scaledWAV(source, gain: 3)!) == [0, 3000, -3000, 32767, -32768, 9], "Out-of-range results clamp instead of wrapping")
        let padded = wav(samples: [200, -200], extraChunk: true)
        check(samples(ControllerSound.scaledWAV(padded, gain: 0.5)!, at: 56) == [100, -100], "Samples are found after an odd-sized extra chunk")
        check(ControllerSound.scaledWAV(wav(samples: [1, 2], format: 3), gain: 0.5) == nil, "Float WAVs are refused")
        check(ControllerSound.scaledWAV(wav(samples: [1, 2], bits: 24), gain: 0.5) == nil, "Other bit depths are refused")
        check(ControllerSound.scaledWAV(Data([1, 2, 3]), gain: 0.5) == nil && ControllerSound.scaledWAV(source.prefix(30), gain: 0.5) == nil, "Truncated or foreign data is refused")
        check(ControllerSound.scaledWAV(source, gain: .nan) == nil, "A non-finite gain is refused")
        print("Controller sound: \(checks) checks passed (injected playback; no audio played)")
    }
}
