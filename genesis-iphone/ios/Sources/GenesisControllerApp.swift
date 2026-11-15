import SwiftUI

@main
struct GenesisControllerApp: App {
    @StateObject private var store = ControllerStore(demo: ProcessInfo.processInfo.arguments.contains("--demo"),
                                                     demoFollow: ProcessInfo.processInfo.arguments.contains("--demo-follow"))
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ControllerScreen(store: store)
                .tint(Color(red: 0.20, green: 0.47, blue: 0.96))
                .preferredColorScheme(.light)
                .onOpenURL { url in Task { do { try await store.pair(url) } catch { store.lastError = error.localizedDescription } } }
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
