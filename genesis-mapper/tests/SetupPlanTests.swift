import Foundation

@main struct SetupPlanTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func main() {
        let home = "/Users/someone"
        let app = "Agent Micro Controller.app"
        expect(SetupPlan.installPlace(bundlePath: "/Applications/\(app)", home: home) == .applications, "The shared Applications folder counts")
        expect(SetupPlan.installPlace(bundlePath: "\(home)/Applications/\(app)", home: home) == .applications, "The user's own Applications folder counts")
        expect(SetupPlan.installPlace(bundlePath: "\(home)/Applications/\(app)/", home: home) == .applications, "A trailing slash changes nothing")
        expect(SetupPlan.installPlace(bundlePath: "\(home)/Downloads/\(app)", home: home) == .elsewhere, "Downloads does not count")
        expect(SetupPlan.installPlace(bundlePath: "/Applications/Tools/\(app)", home: home) == .elsewhere, "A folder inside Applications is not Applications itself")
        expect(SetupPlan.installPlace(bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/\(app)", home: home) == .translocated,
               "A copy macOS runs from its hidden download folder is recognised")
        expect(SetupPlan.installPlace(bundlePath: "/Volumes/Agent Micro Controller/\(app)", home: home) == .elsewhere, "A disk image does not count")

        expect(SetupPlan.destinationFolder(systemWritable: true, home: home) == "/Applications", "Moves to the shared folder when allowed")
        expect(SetupPlan.destinationFolder(systemWritable: false, home: home) == "\(home)/Applications", "Otherwise to the user's own")

        expect(SetupPlan.opensAtLaunch(finished: false, trusted: false, pairedDevices: 0, place: .elsewhere), "A first launch opens setup")
        expect(!SetupPlan.opensAtLaunch(finished: false, trusted: true, pairedDevices: 1, place: .applications),
               "A Mac set up before the window existed is not interrupted")
        expect(SetupPlan.opensAtLaunch(finished: false, trusted: true, pairedDevices: 0, place: .applications), "Unpaired and unfinished opens setup")
        expect(!SetupPlan.opensAtLaunch(finished: true, trusted: true, pairedDevices: 0, place: .applications),
               "Once finished, having no phone paired is not a reason to open at every sign-in")
        expect(SetupPlan.opensAtLaunch(finished: true, trusted: false, pairedDevices: 2, place: .applications), "A lost Accessibility permission brings setup back")
        expect(SetupPlan.opensAtLaunch(finished: true, trusted: true, pairedDevices: 2, place: .translocated), "A copy run from the download brings setup back")

        let installed = "\(home)/Applications/\(app)/Contents/MacOS/GenesisMapper"
        expect(!SetupPlan.loginAgentNeedsRepair(agentProgram: nil, currentProgram: installed, place: .applications), "No agent, nothing to repair")
        expect(!SetupPlan.loginAgentNeedsRepair(agentProgram: installed, currentProgram: installed, place: .applications), "An agent for this copy is left alone")
        expect(SetupPlan.loginAgentNeedsRepair(agentProgram: "/Applications/\(app)/Contents/MacOS/GenesisMapper", currentProgram: installed, place: .applications),
               "An agent for a copy that was moved is pointed at this one")
        expect(!SetupPlan.loginAgentNeedsRepair(agentProgram: installed, currentProgram: "\(home)/Downloads/\(app)/Contents/MacOS/GenesisMapper", place: .elsewhere),
               "A stray copy in Downloads never takes the agent over")

        expect(SetupPlan.noCodeReason(remoteEnabled: false, wifiEnabled: true, wifiSupported: true, hasLocalName: true, hasTailscale: false) == .remoteOff, "Phone access off comes first")
        expect(SetupPlan.noCodeReason(remoteEnabled: true, wifiEnabled: false, wifiSupported: true, hasLocalName: true, hasTailscale: false) == .wifiOff, "Wi-Fi off, no Tailscale")
        expect(SetupPlan.noCodeReason(remoteEnabled: true, wifiEnabled: true, wifiSupported: false, hasLocalName: true, hasTailscale: false) == .needsNewerMacOS, "macOS 14 without Tailscale")
        expect(SetupPlan.noCodeReason(remoteEnabled: true, wifiEnabled: true, wifiSupported: true, hasLocalName: false, hasTailscale: false) == .noLocalName, "No .local name yet")
        expect(SetupPlan.noCodeReason(remoteEnabled: true, wifiEnabled: false, wifiSupported: false, hasLocalName: false, hasTailscale: true) == .starting,
               "With Tailscale there is always a way; the code is just starting")
        expect(SetupPlan.wifiNeedsNewerMacOS.hasPrefix("Wi-Fi pairing needs macOS 15 or later") && SetupPlan.wifiNeedsNewerMacOS.contains("a free app that links your own devices privately"), "macOS 14 wording says why and explains Tailscale")
        expect(SetupPlan.museNote.hasPrefix("Muse has no download link here") && !SetupPlan.museNote.contains("http"), "Muse note gives a next step without a made-up link")
        print("Setup plan: \(checks) checks passed")
    }
}
