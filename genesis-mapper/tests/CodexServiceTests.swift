import Foundation

@main struct CodexServiceTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func main() {
        typealias S = CodexService
        expect(S.state(answering: true, linkPresent: true, targetPresent: true) == .answering, "An answering service is answering")
        expect(S.state(answering: true, linkPresent: false, targetPresent: false) == .answering, "An answer outranks what is on disk")
        expect(S.state(answering: false, linkPresent: true, targetPresent: false) == .connectionLost, "A link with no file behind it is a lost connection")
        expect(S.state(answering: false, linkPresent: true, targetPresent: true) == .notAnswering, "A file that does not answer is a silent service")
        expect(S.state(answering: false, linkPresent: false, targetPresent: false) == .neverSetUp, "No link means the service was never set up")
        expect(S.state(answering: false, linkPresent: false, targetPresent: true) == .neverSetUp, "No link is never set up, whatever else is reported")

        expect(!S.canRestart(.answering), "A service that answers is never restarted")
        expect(!S.canRestart(.neverSetUp), "A service that was never set up is not started from the phone")
        expect(S.canRestart(.connectionLost) && S.canRestart(.notAnswering), "An unreachable service can be restarted")

        expect(S.reason(.answering) == nil, "An answering service needs no explanation")
        expect(S.reason(.connectionLost)?.contains("connection file") == true, "A lost connection is explained")
        expect(S.reason(.notAnswering)?.contains("not answering") == true, "A silent service is explained")
        expect(S.reason(.neverSetUp)?.contains("Open Codex") == true, "A Mac without the service is told to open Codex")
        expect(S.restartArguments == ["app-server", "daemon", "restart"], "The restart command is Codex's own, with no extra arguments")

        var r = S.receipt(.exited(0), answeringAfter: true, chats: 217)
        expect(r.status == "confirmed" && r.message.contains("217 saved chats"), "A restart that brings chats back is confirmed with the count")
        r = S.receipt(.exited(0), answeringAfter: true, chats: 1)
        expect(r.message.contains("1 saved chat found"), "One chat is singular")
        r = S.receipt(.exited(3), answeringAfter: true, chats: 4)
        expect(r.status == "confirmed", "What matters is that the service answers, not the command's exit code")
        r = S.receipt(.timedOut, answeringAfter: true, chats: 4)
        expect(r.status == "confirmed", "A slow command that still worked is confirmed")
        r = S.receipt(.notLaunched, answeringAfter: true, chats: 4)
        expect(r.status == "failed" && r.message.contains("Nothing was changed"), "A command that never started claims nothing")
        r = S.receipt(.notLaunched, answeringAfter: false, chats: 0)
        expect(r.status == "failed", "A command that never started fails")
        r = S.receipt(.exited(0), answeringAfter: false, chats: 0)
        expect(r.status == "uncertain" && r.message.contains("Refresh"), "A clean restart that is not answering yet is uncertain")
        r = S.receipt(.exited(1), answeringAfter: false, chats: 0)
        expect(r.status == "failed" && r.message.contains("codex app-server daemon restart"), "A failed restart says what to run on the Mac")
        r = S.receipt(.timedOut, answeringAfter: false, chats: 0)
        expect(r.status == "uncertain", "A restart that ran out of time is uncertain")

        expect(S.startArguments == ["app-server", "daemon", "start"], "The fallback is Codex's own start command")
        expect(S.shouldTryStart(after: .exited(1), answering: false), "A failed restart that left the service silent gets one start")
        expect(!S.shouldTryStart(after: .exited(1), answering: true), "A service that answers needs no start")
        expect(!S.shouldTryStart(after: .exited(0), answering: false), "A clean restart is given time, not a second command")
        expect(!S.shouldTryStart(after: .timedOut, answering: false) && !S.shouldTryStart(after: .notLaunched, answering: false), "A command that never finished or never ran is not followed by another")

        // The probe on a real folder.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        expect(S.probe(home: home, answering: false) == .neverSetUp, "An empty home has no service")
        let link = S.link(home: home)
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = home.appendingPathComponent("target")
        try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        expect(S.probe(home: home, answering: false) == .connectionLost, "A dangling link is a lost connection")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        expect(S.probe(home: home, answering: false) == .notAnswering, "A link to a file that does not answer is a silent service")
        expect(S.probe(home: home, answering: true) == .answering, "An answer is an answer")
        try! FileManager.default.removeItem(at: target)
        expect(S.probe(home: home, answering: false) == .connectionLost, "Removing the file loses the connection again")

        print("Codex service: \(checks) checks passed")
    }
}
