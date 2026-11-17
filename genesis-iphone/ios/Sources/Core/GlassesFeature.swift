import Foundation

/// Whether the controller shows anything to do with Even G2 glasses.
///
/// The glasses need the separate Genesis G2 app, so someone without them
/// should not see a Follow panel that can never connect. A fresh install
/// starts with the glasses controls hidden. An install that already has a
/// paired Mac comes from a version that always showed them, so it keeps them.
enum GlassesFeature {
    static let key = "glassesFeatureEnabled"
    /// The demo keeps its own setting, turned on at every launch, so previews
    /// and UI tests always start with the glasses controls present.
    static let demoKey = "glassesFeatureEnabled.demo"

    static func storageKey(demo: Bool) -> String { demo ? demoKey : key }

    /// Settles the setting once, at launch. A choice already made is kept.
    static func prepare(_ defaults: UserDefaults, demo: Bool, hasPairedMac: Bool) {
        if demo { defaults.set(true, forKey: demoKey); return }
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(hasPairedMac, forKey: key)
    }
}
