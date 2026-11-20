import Foundation

/// Where the companion is running from.
enum InstallPlace: Equatable {
    /// /Applications or the user's own ~/Applications.
    case applications
    /// Opened straight from the download: macOS runs a read-only copy from a
    /// hidden folder, which moves every launch, so permissions don't stick.
    case translocated
    /// Downloads, the Desktop, a disk image or anywhere else.
    case elsewhere
}

/// Why the setup window has no pairing code to show, so it can say what to do.
enum NoPairingCode: Equatable {
    case remoteOff
    case wifiOff
    case needsNewerMacOS
    case noLocalName
    case starting
}

/// The decisions behind the first-run setup window, kept free of AppKit so
/// they can be tested.
enum SetupPlan {
    static func installPlace(bundlePath: String, home: String) -> InstallPlace {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return .translocated }
        let parent = (path as NSString).deletingLastPathComponent
        let homeApps = ((home as NSString).appendingPathComponent("Applications") as NSString).standardizingPath
        return parent == "/Applications" || parent == homeApps ? .applications : .elsewhere
    }

    /// The folder "Move to Applications" puts the app in: the shared one when
    /// this user can write to it, otherwise their own.
    static func destinationFolder(systemWritable: Bool, home: String) -> String {
        systemWritable ? "/Applications" : (home as NSString).appendingPathComponent("Applications")
    }

    /// A Mac counts as set up, even one set up before this window existed,
    /// once the app is installed, allowed and paired with a device.
    static func alreadySetUp(trusted: Bool, pairedDevices: Int, place: InstallPlace) -> Bool {
        trusted && pairedDevices > 0 && place == .applications
    }

    /// Whether setup opens by itself at launch. After it is finished it comes
    /// back only for something that stops the app working: a lost
    /// Accessibility permission or a copy outside Applications.
    static func opensAtLaunch(finished: Bool, trusted: Bool, pairedDevices: Int, place: InstallPlace) -> Bool {
        if !finished { return !alreadySetUp(trusted: trusted, pairedDevices: pairedDevices, place: place) }
        return !trusted || place != .applications
    }

    /// Whether the sign-in agent must be pointed at this copy: it runs another
    /// path (the app was moved) and this copy is the installed one.
    static func loginAgentNeedsRepair(agentProgram: String?, currentProgram: String, place: InstallPlace) -> Bool {
        guard let agentProgram, place == .applications else { return false }
        return agentProgram != currentProgram
    }

    /// Why there is no code on screen. Wi-Fi is the way to pair without
    /// Tailscale, so its problems come first.
    static func noCodeReason(remoteEnabled: Bool, wifiEnabled: Bool, wifiSupported: Bool,
                             hasLocalName: Bool, hasTailscale: Bool) -> NoPairingCode {
        if !remoteEnabled { return .remoteOff }
        if hasTailscale { return .starting }
        if !wifiSupported { return .needsNewerMacOS }
        if !wifiEnabled { return .wifiOff }
        if !hasLocalName { return .noLocalName }
        return .starting
    }
}
