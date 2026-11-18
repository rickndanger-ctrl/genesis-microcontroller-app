import Foundation

struct LoginLaunch {
    static let label="local.richard.claude-controller.login"
    static var file: URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")}
    static var enabled: Bool {FileManager.default.fileExists(atPath:file.path)}
    /// The sign-in agent. It runs the app's own program, not `open`, so that
    /// launchd is watching it: if the companion crashes or is killed it is
    /// started again, and if you quit it (a clean exit) it stays quit.
    static func agent(appPath:String)->[String:Any] {
        ["Label":label,
         "ProgramArguments":[appPath+"/Contents/MacOS/GenesisMapper"],
         "RunAtLoad":true,
         "KeepAlive":["SuccessfulExit":false],
         "ThrottleInterval":10,
         "ProcessType":"Interactive",
         "LimitLoadToSessionType":"Aqua"]
    }
    /// True when another copy of this app is already running. The agent can
    /// start the program while a copy opened by hand is still up; the newcomer
    /// then leaves, cleanly, so launchd does not start it again.
    static func anotherCopyIsRunning(mine:Int32,running:[Int32])->Bool {running.contains{$0 != mine}}
    /// The program the sign-in agent starts, or nil when there is no agent.
    static var agentProgram: String? {
        guard let data=try? Data(contentsOf:file),
              let plist=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else{return nil}
        return (plist["ProgramArguments"] as? [String])?.first
    }
    /// This copy's own program, which the agent should start.
    static var currentProgram: String {Bundle.main.bundlePath+"/Contents/MacOS/GenesisMapper"}
    static func set(_ enabled: Bool) throws {
        let domain="gui/\(getuid())"
        func run(_ arguments: [String]) -> Int32 {
            let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/launchctl");p.arguments=arguments
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            do {try p.run();p.waitUntilExit();return p.terminationStatus} catch {return -1}
        }
        if enabled {
            // The copy that is running, wherever it was installed.
            let app=Bundle.main.bundlePath
            let data=try PropertyListSerialization.data(fromPropertyList:agent(appPath:app),format:.xml,options:0)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:file,options:.atomic)
            _=run(["bootout",domain+"/"+label]);_ = run(["bootstrap",domain,file.path])
        } else {
            _=run(["bootout",domain+"/"+label])
            if self.enabled {try FileManager.default.removeItem(at:file)}
        }
    }
}
