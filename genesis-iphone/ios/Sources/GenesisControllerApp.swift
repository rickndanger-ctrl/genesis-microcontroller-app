import SwiftUI

@main
struct GenesisControllerApp: App {
    @StateObject private var store = GenesisControllerApp.makeStore()
    /// A sample controller with no Mac behind it, opened with Try the demo.
    /// It never reads or writes the real controller's pairings or settings.
    @State private var demo: ControllerStore?
    @Environment(\.scenePhase) private var scenePhase

    private static func makeStore() -> ControllerStore {
        ControllerStore.deviceName = { UIDevice.current.name }
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        // UI tests use this to see what a brand-new install shows, whatever
        // this simulator has paired before. Nothing is read from or saved to
        // the app's real storage or keychain.
        if arguments.contains("--fresh-install") {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("genesis-fresh-\(UUID().uuidString)", isDirectory: true)
            return ControllerStore(credentials: EphemeralCredentials(), persistence: ControllerPersistence(directory: scratch), glassesPreferences: nil)
        }
        #endif
        return ControllerStore(demo: arguments.contains("--demo"), demoFollow: arguments.contains("--demo-follow"))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let demo {
                    ControllerScreen(store: demo, endDemo: { self.demo = nil })
                } else {
                    // Offered only where there is nothing to lose sight of: no Mac paired yet.
                    ControllerScreen(store: store, startDemo: store.isDemo ? nil : { self.demo = ControllerStore(demo: true) })
                }
            }
                .tint(Color(red: 0.20, green: 0.47, blue: 0.96))
                .preferredColorScheme(.light)
                .onOpenURL { url in demo = nil; Task { do { try await store.pair(url) } catch { store.lastError = error.localizedDescription } } }
                .task { store.setForeground(true) }
                .onReceive(store.glasses.$enabled) { enabled in
                    UIApplication.shared.isIdleTimerDisabled = enabled && scenePhase == .active
                }
                .onChange(of: scenePhase) { _, phase in
                    // Permission alerts temporarily make the scene inactive. Keep
                    // their in-flight authorization alive until the user responds.
                    if phase == .active { store.setForeground(true) }
                    else if phase == .background { store.setForeground(false) }
                    UIApplication.shared.isIdleTimerDisabled = store.glasses.enabled && phase == .active
                }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}

#if DEBUG
/// Credentials that live only as long as the process, for `--fresh-install`.
private final class EphemeralCredentials: ControllerCredentialVault {
    private var tokens: [String: String] = [:]
    func token(for hostID: String) -> String? { tokens[hostID] }
    func save(_ token: String, for hostID: String) throws { tokens[hostID] = token }
    func remove(for hostID: String) { tokens[hostID] = nil }
}
#endif
