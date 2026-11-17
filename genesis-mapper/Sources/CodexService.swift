import Foundation

/// Codex keeps its saved chats behind a small background service. The service
/// is reached through a file that lives in the system's temporary folder, and
/// macOS clears that folder every few days. The service keeps running, but
/// nothing can reach it until it is restarted.
enum CodexService {
    enum State: Equatable {
        /// The service answered the last time it was asked.
        case answering
        /// The link to the service is there, but the file it points at is gone.
        case connectionLost
        /// The file is there, but the service does not answer.
        case notAnswering
        /// This Mac has never run the service, so there is nothing to restart.
        case neverSetUp
    }
    /// How the restart command ended.
    enum Run: Equatable { case notLaunched, exited(Int32), timedOut }

    static let restartArguments = ["app-server", "daemon", "restart"]
    /// A restart stops the service before starting it. If the start half fails,
    /// one plain start is tried so the service is not left stopped.
    static let startArguments = ["app-server", "daemon", "start"]
    static func shouldTryStart(after run: Run, answering: Bool) -> Bool {
        if answering { return false }
        if case .exited(let code) = run { return code != 0 }
        return false
    }

    static func state(answering: Bool, linkPresent: Bool, targetPresent: Bool) -> State {
        if answering { return .answering }
        if !linkPresent { return .neverSetUp }
        return targetPresent ? .notAnswering : .connectionLost
    }

    /// A restart is offered only when the service cannot be reached, so it can
    /// never interrupt a service that something is using through that route.
    static func canRestart(_ state: State) -> Bool { state == .connectionLost || state == .notAnswering }

    static func reason(_ state: State) -> String? {
        switch state {
        case .answering: return nil
        case .connectionLost: return "Codex\u{2019}s background service lost its connection file, which macOS clears from time to time. Restart the service to bring saved chats back."
        case .notAnswering: return "Codex\u{2019}s background service is not answering. Restart the service to bring saved chats back."
        case .neverSetUp: return "The current-account Codex chat inventory is unavailable. Open Codex on this Mac and refresh."
        }
    }

    static func receipt(_ run: Run, answeringAfter: Bool, chats: Int) -> (status: String, message: String) {
        if answeringAfter, run != .notLaunched {
            return ("confirmed", "Codex\u{2019}s background service is answering again. \(chats) saved chat\(chats == 1 ? "" : "s") found.")
        }
        switch run {
        case .notLaunched: return ("failed", "Codex\u{2019}s restart command could not start. Nothing was changed.")
        case .exited(0): return ("uncertain", "Codex\u{2019}s background service was restarted but is not answering yet. Refresh in a moment.")
        case .exited: return ("failed", "Codex could not restart its background service. On the Mac, run: codex app-server daemon restart")
        case .timedOut: return ("uncertain", "Codex\u{2019}s restart took too long to finish. Refresh in a moment to see whether saved chats are back.")
        }
    }

    /// The link Codex leaves in its own folder, pointing at the connection file.
    static func link(home: URL) -> URL {
        home.appendingPathComponent(".codex/app-server-control/app-server-control.sock")
    }

    /// Looks at the link and its target on disk. Reads nothing from either.
    static func probe(home: URL, answering: Bool) -> State {
        let path = link(home: home).path
        // attributesOfItem does not follow the link; fileExists does.
        let linkPresent = (try? FileManager.default.attributesOfItem(atPath: path)) != nil
        return state(answering: answering, linkPresent: linkPresent, targetPresent: FileManager.default.fileExists(atPath: path))
    }
}
