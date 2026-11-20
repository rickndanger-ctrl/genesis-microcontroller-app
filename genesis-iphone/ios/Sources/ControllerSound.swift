import AudioToolbox
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ControllerSound {
    static let shared = ControllerSound()
    static let preferenceKey = "controllerSoundsEnabled"
    static let packKey = "controllerSoundPack"
    static let volumeKey = "controllerSoundVolume"

    enum Event: Equatable { case key, detent }

    /// A matched key click and dial detent. `design/build_sounds.py` builds
    /// every pack except Soft, which is the original quiet pair.
    struct Pack: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let keyFile: String
        let dialFile: String
    }
    static let packs: [Pack] = [
        Pack(id: "crunch", title: "Crunch", detail: "Sharp and gritty, with a clicky upstroke", keyFile: "ClickCrunchKey", dialFile: "ClickCrunchDial"),
        Pack(id: "thock", title: "Thock", detail: "Deep and rounded", keyFile: "ClickThockKey", dialFile: "ClickThockDial"),
        Pack(id: "clack", title: "Clack", detail: "Bright, with a metallic ring", keyFile: "ClickClackKey", dialFile: "ClickClackDial"),
        Pack(id: "arcade", title: "Arcade", detail: "A hard, fast double snap", keyFile: "ClickArcadeKey", dialFile: "ClickArcadeDial"),
        Pack(id: "soft", title: "Soft", detail: "The original quiet tick", keyFile: "KeyClick", dialFile: "DialTick"),
    ]
    static let defaultPack = packs[0]
    static let defaultVolume = 1.0
    static let volumeStep = 0.05

    // Read the store's current authorizing/recording/finalizing state at the
    // actual tap, including actions in sheets. Never queue a suppressed sound.
    var captureIsActive: @MainActor () -> Bool
    private let preferences: UserDefaults
    private let applicationIsActive: @MainActor () -> Bool
    private let playback: ((Event) -> Void)?
    private var loaded: [Event: SystemSoundID] = [:]
    private var loadedConfiguration = ""

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

    /// The chosen pack. An unknown stored value falls back to the default
    /// rather than going silent.
    var pack: Pack {
        let stored = preferences.string(forKey: Self.packKey)
        return Self.packs.first { $0.id == stored } ?? Self.defaultPack
    }

    /// 0…1, snapped to the control's steps.
    var volume: Double {
        let stored = preferences.object(forKey: Self.volumeKey) as? Double ?? Self.defaultVolume
        guard stored.isFinite else { return Self.defaultVolume }
        return (min(1, max(0, stored)) / Self.volumeStep).rounded() * Self.volumeStep
    }

    func dialTick() {
        play(.detent)
    }

    func keyClick() {
        play(.key)
    }

    private func play(_ event: Event) {
        guard enabled, volume > 0, applicationIsActive(), !captureIsActive() else { return }
        if let playback { playback(event); return }
        // System UI sounds retain the user's system volume/silent behavior.
        // Do not activate or reconfigure the dictation audio session.
        if let sound = sound(for: event) { AudioServicesPlaySystemSound(sound) }
    }

    private var enabled: Bool {
        preferences.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    /// Slider position to linear gain. Loudness is roughly logarithmic, so an
    /// even slider needs a curved gain.
    nonisolated static func gain(forVolume volume: Double) -> Double {
        pow(min(1, max(0, volume)), 2)
    }

    private func sound(for event: Event) -> SystemSoundID? {
        let pack = pack, volume = volume
        let configuration = "\(pack.id)@\(Int((volume * 100).rounded()))"
        if configuration != loadedConfiguration {
            loaded.values.forEach { AudioServicesDisposeSystemSoundID($0) }
            loaded = [:]
            loadedConfiguration = configuration
        }
        if let id = loaded[event] { return id }
        let name = event == .key ? pack.keyFile : pack.dialFile
        guard let source = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(rendered(source, name: name, volume: volume) as CFURL, &id) == kAudioServicesNoError else { return nil }
        loaded[event] = id
        return id
    }

    /// System sounds have no volume of their own, so anything below full is
    /// played from a scaled copy in the temporary directory.
    private func rendered(_ source: URL, name: String, volume: Double) -> URL {
        guard volume < 1, let original = try? Data(contentsOf: source),
              let scaled = Self.scaledWAV(original, gain: Self.gain(forVolume: volume)) else { return source }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GenesisClicks", isDirectory: true)
        let copy = folder.appendingPathComponent("\(name)-\(Int((volume * 100).rounded())).wav")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try scaled.write(to: copy, options: .atomic)
            return copy
        } catch {
            return source
        }
    }

    /// Returns a copy of a 16-bit PCM WAV with every sample multiplied by
    /// `gain` and clamped, or `nil` for any other format.
    nonisolated static func scaledWAV(_ wav: Data, gain: Double) -> Data? {
        let bytes = [UInt8](wav)
        func tag(_ offset: Int) -> String? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
        }
        func uint(_ offset: Int, _ length: Int) -> Int? {
            guard offset >= 0, offset + length <= bytes.count else { return nil }
            return (0..<length).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        guard gain.isFinite, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var offset = 12
        var pcm16 = false
        var output = bytes
        while let id = tag(offset), let size = uint(offset + 4, 4) {
            let body = offset + 8
            if id == "fmt " {
                guard let format = uint(body, 2), let bits = uint(body + 14, 2) else { return nil }
                pcm16 = format == 1 && bits == 16
            } else if id == "data" {
                guard pcm16 else { return nil }
                let end = min(bytes.count, body + size)
                var index = body
                while index + 1 < end {
                    let sample = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                    let scaled = (Double(sample) * gain).rounded()
                    let clamped = UInt16(bitPattern: Int16(max(-32768, min(32767, scaled))))
                    output[index] = UInt8(clamped & 0xFF)
                    output[index + 1] = UInt8(clamped >> 8)
                    index += 2
                }
                return Data(output)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
