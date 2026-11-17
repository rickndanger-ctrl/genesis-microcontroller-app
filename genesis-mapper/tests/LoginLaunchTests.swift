import Foundation

@main struct LoginLaunchTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func main() {
        let agent = LoginLaunch.agent(appPath: "/Users/someone/Applications/Agent Micro Controller.app")
        expect(agent["Label"] as? String == LoginLaunch.label, "The agent keeps its label, so an update replaces the old one")
        expect(agent["ProgramArguments"] as? [String] == ["/Users/someone/Applications/Agent Micro Controller.app/Contents/MacOS/GenesisMapper"],
               "The agent runs the app's own program, so launchd is watching the companion itself")
        expect(agent["RunAtLoad"] as? Bool == true, "It starts at sign-in")
        expect((agent["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false], "It is restarted after a crash or a kill, but not after a clean quit")
        expect(agent["LimitLoadToSessionType"] as? String == "Aqua", "It runs only in a signed-in desktop session")
        expect((agent["ThrottleInterval"] as? Int ?? 0) >= 10, "A companion that keeps failing is not restarted in a tight loop")
        expect((try? PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)) != nil, "The agent is a valid property list")

        expect(!LoginLaunch.anotherCopyIsRunning(mine: 100, running: [100]), "The only copy stays")
        expect(!LoginLaunch.anotherCopyIsRunning(mine: 100, running: []), "A copy not yet listed stays")
        expect(LoginLaunch.anotherCopyIsRunning(mine: 100, running: [90, 100]), "A second copy sees the first")
        expect(LoginLaunch.anotherCopyIsRunning(mine: 100, running: [90]), "A newcomer not yet listed still sees the first")
        print("Login launch: \(checks) checks passed")
    }
}
