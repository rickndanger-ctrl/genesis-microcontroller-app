import AppKit
import ApplicationServices

/// Adapts the existing physical controller navigator without sharing its cursor
/// state. Every input resolves the current popup again and checks its lease.
@MainActor final class RemoteMenuNavigation {
    struct Outcome {
        let success: Bool
        let state: RemoteNavigationState
        let message: String
        var selectionWasFile = false
    }
    private let navigator = MenuNavigator()
    private var lease: RemoteNavigationLease?
    private var root: AXUIElement?
    private var pid: pid_t?
    private var busy = false

    func invalidate() {
        lease = nil; root = nil; pid = nil
        navigator.resetFileEntry()
    }
    private func mode(_ provider: String) -> String? {
        provider == "claude" ? "Claude" : provider == "codex" ? "Codex" : nil
    }
    private func accepts(_ session: String, provider: String, chatID: String?, generation: Int) -> Bool {
        lease?.accepts(session: session, provider: provider, chatID: chatID, generation: generation,
            now: ProcessInfo.processInfo.systemUptime) == true
    }
    func inspect(provider: String, chatID: String?, generation: Int, isCurrent: () -> Bool) async -> RemoteNavigationState {
        guard !busy else {
            return RemoteNavigationState(active: false, session: nil, label: "Finishing the previous menu action…", selection: nil)
        }
        busy = true
        defer { busy = false }
        return await resolve(provider: provider, chatID: chatID, generation: generation, isCurrent: isCurrent)
    }
    private func resolve(provider: String, chatID: String?, generation: Int, isCurrent: () -> Bool) async -> RemoteNavigationState {
        guard generation >= 0, isCurrent(), let mode = mode(provider),
              let snapshot = await navigator.snapshot(mode: mode), isCurrent() else {
            invalidate(); return .inactive
        }
        let sameRoot = root.map { CFEqual($0, snapshot.root) } ?? false
        let reusable = lease.map { accepts($0.session, provider: provider, chatID: chatID, generation: generation) } ?? false
        if !sameRoot || pid != snapshot.pid || !reusable {
            invalidate()
            lease = RemoteNavigationLease(session: UUID().uuidString, provider: provider, chatID: chatID,
                generation: generation, observedAt: ProcessInfo.processInfo.systemUptime)
            root = snapshot.root; pid = snapshot.pid
        }
        guard let session = lease?.session else { return .inactive }
        await navigator.prepareFileEntry(snapshot, isCurrent: {
            isCurrent() && self.accepts(session, provider: provider, chatID: chatID, generation: generation)
        })
        guard isCurrent(), accepts(session, provider: provider, chatID: chatID, generation: generation) else {
            invalidate(); return .inactive
        }
        lease?.observedAt = ProcessInfo.processInfo.systemUptime
        return RemoteNavigationState(active: true, session: session, label: navigator.label(for: snapshot),
            selection: navigator.selectionLabel(for: snapshot))
    }
    func perform(action: String, session: String, provider: String, chatID: String?, generation: Int,
                 isCurrent: () -> Bool) async -> Outcome {
        // A phone poll may already be resolving the same popup. Let its bounded
        // read finish instead of dropping the user's deliberate tap. No input is
        // queued or replayed, and the lease is rechecked after waiting.
        let waitDeadline = ProcessInfo.processInfo.systemUptime + 1
        while busy && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < waitDeadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard !busy, RemoteNavigationLease.commands.contains(action), isCurrent(),
              accepts(session, provider: provider, chatID: chatID, generation: generation),
              let mode = mode(provider), let expectedRoot = root, let expectedPID = pid else {
            return Outcome(success: false, state: .inactive, message: "This menu changed. Refresh its controls before trying again.")
        }
        busy = true
        defer { busy = false }
        func current() -> Bool {
            isCurrent() && accepts(session, provider: provider, chatID: chatID, generation: generation)
        }
        guard let snapshot = await navigator.snapshot(mode: mode), current(), snapshot.pid == expectedPID,
              CFEqual(snapshot.root, expectedRoot) else {
            invalidate()
            return Outcome(success: false, state: .inactive, message: "The original menu is no longer open. No input sent.")
        }
        var success: Bool
        if action == "menuHome" {
            success = false
            var candidate: MenuNavigator.Snapshot? = snapshot
            // Escape only a bounded, recognized popup stack. Never close a chat.
            for _ in 0..<4 {
                guard let panel = candidate, panel.pid == expectedPID, current() else { break }
                guard await navigator.perform("cancel", direction: 0, in: panel, isCurrent: current) else { break }
                success = true
                try? await Task.sleep(nanoseconds: 100_000_000)
                candidate = await navigator.snapshot(mode: mode)
            }
            invalidate()
            return Outcome(success: success, state: .inactive,
                message: success ? "Closed the recognized menu and returned to chat selection." : "The menu could not be closed. No other window was touched.")
        }
        let kind = action == "menuSelect" ? "select" : action == "menuBack" ? "back" : "turn"
        let direction = action == "menuPrevious" ? -1 : action == "menuNext" ? 1 : 0
        success = await navigator.perform(kind, direction: direction, in: snapshot, isCurrent: current)
        if kind != "turn" { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard isCurrent() else {
            invalidate()
            // A selection can intentionally leave its chat/search menu. Report
            // the accepted input honestly; the bridge independently observes
            // the new chat before the phone enables a destination-sensitive action.
            return Outcome(success: success, state: .inactive,
                message: success ? "Requested menu navigation; the previous menu context has ended." : "The navigation context changed. Refresh before continuing.")
        }
        let state = await resolve(provider: provider, chatID: chatID, generation: generation, isCurrent: isCurrent)
        return Outcome(success: success, state: state,
            message: success ? "Requested menu navigation." : "This control is unavailable to the navigator. Photos library thumbnails still need the mouse.",
            selectionWasFile: action == "menuSelect" && snapshot.kind == .file)
    }
}
