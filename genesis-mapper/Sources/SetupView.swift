import SwiftUI
import AppKit
import ApplicationServices
import Darwin

/// The agent apps the companion drives, and where to get each one.
struct SetupAgent: Identifiable {
    let id: String, name: String, bundle: String, download: URL?
    static let all = [
        SetupAgent(id: "claude", name: "Claude", bundle: "com.anthropic.claudefordesktop", download: URL(string: "https://claude.ai/download")),
        SetupAgent(id: "codex", name: "Codex", bundle: "com.openai.codex", download: URL(string: "https://openai.com/codex/")),
        SetupAgent(id: "muse", name: "Muse", bundle: "com.meta.endo", download: nil),
    ]
    var installedURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }
    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }
}

/// What the setup window shows, read again every second so each step ticks
/// as soon as it is done, in this window or in System Settings.
@MainActor final class SetupState: ObservableObject {
    static let finishedKey = "setup.finished"
    @Published var place = SetupState.currentPlace
    @Published var trusted = AXIsProcessTrusted()
    @Published var agents: [(agent: SetupAgent, installed: Bool, running: Bool)] = []
    @Published var moveError: String?
    @Published var moving = false
    private var timer: Timer?

    static var currentPlace: InstallPlace {
        SetupPlan.installPlace(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory())
    }
    static var finished: Bool {
        get { UserDefaults.standard.bool(forKey: finishedKey) }
        set { UserDefaults.standard.set(newValue, forKey: finishedKey) }
    }

    func start() {
        read()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.read() } }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func read() {
        let now = AXIsProcessTrusted(); if now != trusted { trusted = now }
        let agentsNow = SetupAgent.all.map { ($0, $0.installedURL != nil, $0.running) }
        if agentsNow.map({ "\($0.1)\($0.2)" }) != agents.map({ "\($0.installed)\($0.running)" }) { agents = agentsNow }
    }

    /// Shows macOS's own Accessibility request, which also puts this app in the
    /// list in System Settings so there is only a switch to turn on.
    func askForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    }
    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func clearQuarantine(_ url: URL) {
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? strip.run(); strip.waitUntilExit()
    }
    /// Where a copy macOS runs from its hidden folder really lives, such as
    /// ~/Downloads. Uses the system call made for exactly this question.
    static func originalLocation(of translocated: URL) -> URL? {
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Original.self)
        guard let url = original(translocated as CFURL, nil)?.takeRetainedValue() as URL?,
              !url.path.contains("/AppTranslocation/") else { return nil }
        return url
    }

    /// Copies this app into Applications, opens the new copy and quits. An
    /// older copy already there goes to the Trash, as does the original when it
    /// can be moved (a copy macOS is running from a hidden folder cannot).
    func moveToApplications() {
        moving = true; moveError = nil
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let folder = URL(fileURLWithPath: SetupPlan.destinationFolder(systemWritable: fm.isWritableFile(atPath: "/Applications"), home: NSHomeDirectory()))
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
            try fm.copyItem(at: source, to: destination)
            // The copy keeps the "downloaded from the internet" mark, and macOS
            // runs a marked app from a hidden folder again, so setup would ask
            // to move it forever. Gatekeeper has already checked this app (it
            // is open), so the installed copy drops the mark, as a Finder move would.
            SetupState.clearQuarantine(destination)
            // The original goes to the Trash, so only one copy is left to find.
            if let original = place == .translocated ? SetupState.originalLocation(of: source) : source,
               original.standardizedFileURL != destination.standardizedFileURL {
                try? fm.trashItem(at: original, resultingItemURL: nil)
            }
        } catch {
            moving = false
            moveError = "Could not move the app: \(error.localizedDescription) Drag Agent Micro Controller into Applications in the Finder instead."
            return
        }
        // The new copy must start after this one has quit, or it would see this
        // one running and leave.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                              String(ProcessInfo.processInfo.processIdentifier), destination.path]
        do { try relaunch.run() } catch {
            moving = false
            moveError = "The app was copied to \(folder.path). Open it from there."
            return
        }
        NSApp.terminate(nil)
    }
}

struct SetupView: View {
    @ObservedObject var bridge: GenesisRemoteBridge
    @ObservedObject var model: Model
    @StateObject private var state = SetupState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private let accent = Color(red: 0.61, green: 0.36, blue: 0.96)

    private var installed: Bool { state.place == .applications }
    private var anyAgent: Bool { state.agents.contains { $0.installed } }
    private var paired: Bool { !bridge.devices.isEmpty }
    private var allDone: Bool { installed && state.trusted && anyAgent && paired }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    if let url = Bundle.main.url(forResource: "Genesis", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Set up Agent Micro Controller").font(.title.bold())
                        Text("Four steps, and your iPhone or iPad controls the agents on this Mac.").foregroundStyle(.secondary)
                    }
                }
                step(1, "Put the app in Applications", done: installed) { moveStep }
                step(2, "Allow it to use your agent apps", done: state.trusted, enabled: installed) { accessibilityStep }
                step(3, "Your agent apps", done: anyAgent) { agentsStep }
                step(4, "Scan this code with your phone", done: paired, enabled: installed) { pairStep }
                HStack {
                    Toggle("Start automatically when I sign in", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        .disabled(!installed)
                    Spacer()
                    if allDone {
                        Button("Done") { SetupState.finished = true; dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    } else {
                        Button("Finish later") { dismiss() }
                    }
                }.padding(.top, 4)
                Text("You can come back here any time from the dial in the menu bar.").font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
        .frame(minWidth: 620, minHeight: 640)
        .tint(accent)
        .onAppear {
            state.start()
            SetupWindow.bringForward()
            // Starting at sign-in is what people expect; turn it on once, the
            // first time the app runs from Applications.
            if installed, !model.loginEnabled, !UserDefaults.standard.bool(forKey: "setup.loginOffered") {
                UserDefaults.standard.set(true, forKey: "setup.loginOffered"); model.setLogin(true)
            }
        }
        .onDisappear { state.stop() }
        .onChange(of: allDone) { _, done in if done { SetupState.finished = true } }
        // A code lasts ten minutes; replace it a little before that while the window is open.
        // Closing the window cancels this task, which retires every live code.
        .task {
            bridge.pairingWindowOpened(); defer { bridge.pairingWindowClosed() }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 540_000_000_000); if !Task.isCancelled { bridge.refreshPairingCode() } }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, enabled: Bool = true,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : accent.opacity(enabled ? 0.9 : 0.3)).frame(width: 30, height: 30)
                if done { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
                if enabled { content() }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(done ? Color.green.opacity(0.07) : Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var moveStep: some View {
        if installed {
            Text("Installed.").font(.callout).foregroundStyle(.secondary)
        } else {
            Text("It’s running from \(state.place == .translocated ? "your download" : "outside Applications"). Moving it makes the next steps stick.").font(.callout)
            Button(state.moving ? "Moving…" : "Move to Applications") { state.moveToApplications() }
                .controlSize(.large).disabled(state.moving)
            if let error = state.moveError { Text(error).font(.callout).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private var accessibilityStep: some View {
        if state.trusted {
            Text("Allowed. The app can press buttons in Claude, Codex and Muse for you.").font(.callout).foregroundStyle(.secondary)
        } else {
            Text("macOS asks first. Turn on Agent Micro Controller in the list that opens; this step ticks by itself.").font(.callout)
            HStack {
                Button("Allow…") { state.askForAccessibility() }.controlSize(.large)
                Button("Open System Settings") { state.openAccessibilitySettings() }
            }
        }
    }

    @ViewBuilder private var agentsStep: some View {
        Text(anyAgent ? "Found on this Mac. Keep the ones you use open." : "Install at least one of these.").font(.callout).foregroundStyle(anyAgent ? .secondary : .primary)
        Text(SetupPlan.museNote).font(.caption).foregroundStyle(.secondary)
        ForEach(state.agents, id: \.agent.id) { row in
            HStack(spacing: 10) {
                Image(systemName: row.installed ? (row.running ? "checkmark.circle.fill" : "circle.dashed") : "xmark.circle")
                    .foregroundStyle(row.installed ? (row.running ? Color.green : Color.secondary) : Color.secondary)
                Text(row.agent.name).frame(width: 64, alignment: .leading)
                Text(row.installed ? (row.running ? "Open" : "Installed, not open") : "Not installed").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if row.installed && !row.running, let url = row.agent.installedURL {
                    Button("Open") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                } else if !row.installed, let download = row.agent.download {
                    Button("Get \(row.agent.name)") { NSWorkspace.shared.open(download) }
                }
            }
        }
    }

    @ViewBuilder private var pairStep: some View {
        if let image = bridge.qrImage {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 190, height: 190)
                    .padding(10).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Point your iPhone’s camera at the code, then tap the link.").font(.callout.weight(.medium))
                    Text("Or open Agent Micro Controller, tap Pair a Mac, then Scan pairing code. Your phone needs to be on the same Wi-Fi as this Mac.").font(.callout).foregroundStyle(.secondary)
                    Link("Get the iPhone and iPad app", destination: URL(string: "https://apps.apple.com/app/id6835749940")!).font(.callout)
                    Text("The code works once and for ten minutes. Show it only to your own devices.").font(.caption).foregroundStyle(.secondary)
                    if let device = bridge.devices.max(by: { $0.pairedAt < $1.pairedAt }) {
                        Label("Paired with \(device.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium))
                    }
                }
            }
        } else {
            noCode
        }
    }

    @ViewBuilder private var noCode: some View {
        let hasTailscale = !bridge.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let supported: Bool = { if #available(macOS 15.0, *) { return true } else { return false } }()
        switch SetupPlan.noCodeReason(remoteEnabled: bridge.enabled, wifiEnabled: bridge.wifiEnabled, wifiSupported: supported,
                                      hasLocalName: WiFiIdentity.localHostName != nil, hasTailscale: hasTailscale) {
        case .remoteOff:
            Text("Phone access is turned off on this Mac.").font(.callout)
            Button("Turn it on") { bridge.setEnabled(true) }.controlSize(.large)
        case .wifiOff:
            Text("Pairing over Wi-Fi is off.").font(.callout)
            Button("Turn on Wi-Fi pairing") { bridge.setWiFi(true) }.controlSize(.large)
        case .needsNewerMacOS:
            Text(SetupPlan.wifiNeedsNewerMacOS).font(.callout)
            HStack {
                Button("Software Update") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!) }
                Button("Tailscale settings…") { openWindow(id: "phone-pairing"); NSApp.activate() }
            }
        case .noLocalName:
            Text("This Mac has no network name yet. Check that it’s on Wi-Fi, then wait a moment.").font(.callout)
        case .starting:
            Text(bridge.wifiStatus).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The menu bar dial. It is drawn as the app starts, so it is also where the
/// setup window gets opened when there is something left to do.
struct MenuBarDial: View {
    @ObservedObject var bridge: GenesisRemoteBridge
    @Environment(\.openWindow) private var openWindow
    private static var checked = false
    var body: some View {
        Image(systemName: "dial.medium.fill")
            // Opening the app again (from Applications, Launchpad or Spotlight)
            // shows setup, for anyone who can't find the dial in a crowded menu bar.
            .onReceive(NotificationCenter.default.publisher(for: SetupWindow.reopen)) { _ in
                openWindow(id: "setup"); SetupWindow.bringForward()
            }
            .onAppear {
            guard !Self.checked else { return }
            Self.checked = true
            let place = SetupState.currentPlace
            if place == .applications, SetupPlan.loginAgentNeedsRepair(agentProgram: LoginLaunch.agentProgram, currentProgram: LoginLaunch.currentProgram, place: place) {
                try? LoginLaunch.set(true)
            }
            if SetupPlan.opensAtLaunch(finished: SetupState.finished, trusted: AXIsProcessTrusted(), pairedDevices: bridge.devices.count, place: place) {
                openWindow(id: "setup"); SetupWindow.bringForward()
            } else if !SetupState.finished {
                SetupState.finished = true
            }
        }
    }
}

/// A menu bar app is not the active app when its window opens, and macOS may
/// leave that window behind whatever was in front. Setup must be seen.
@MainActor enum SetupWindow {
    static let reopen = Notification.Name("SetupWindow.reopen")
    static func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("setup") == true || window.title == "Set Up Agent Micro Controller" {
                window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
            }
        }
    }
}

/// Hears macOS's "the app was opened again" event, which a menu bar app with
/// no window open otherwise ignores.
final class SetupAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NotificationCenter.default.post(name: SetupWindow.reopen, object: nil) }
        return true
    }
}
