import SwiftUI
import UIKit

struct ActionCatalogSections: View {
    @ObservedObject var store: ControllerStore
    let query: String
    var executing = false
    let choose: (RemoteAction) -> Void
    private var actions: [RemoteAction] { store.availableActions.filter { $0.matches(query) } }
    private var groups: [String] {
        let values = Set(actions.map(\.group))
        return RemoteAction.groupOrder.filter(values.contains) + values.filter { !RemoteAction.groupOrder.contains($0) }.sorted()
    }
    var body: some View {
        ForEach(groups, id: \.self) { group in
            Section(group) {
                ForEach(actions.filter { $0.group == group }) { action in
                    let unavailable = executing && !store.canRunAction(action.id)
                    Button {
                        // Running Dictate may open the microphone immediately.
                        // Assignment choices are ordinary buttons, not capture.
                        if !executing || action.id != "dictate" { ControllerSound.shared.keyClick() }
                        choose(action)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: action.icon).frame(width: 22).padding(.top, 2)
                            // Only the icon carries the tint. Tinted body text reads
                            // as pale blue on white and is hard to make out.
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title).foregroundStyle(Color.primary)
                                Text(executing ? store.actionUnavailableReason(action.id) ?? action.detail : action.detail).font(.caption).foregroundStyle(Color.secondary)
                            }
                        }.padding(.vertical, 4).opacity(unavailable ? 0.45 : 1)
                    }.disabled(unavailable)
                }
            }
        }
        if actions.isEmpty {
            Section { Text(query.isEmpty ? "No supported actions are available for this connection." : "No actions match your search.").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

struct ActionBrowser: View {
    @ObservedObject var store: ControllerStore
    var quickKey: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var saving = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("\(store.selectedHost?.name ?? "Mac") · \(store.selectedProvider.name)", systemImage: "desktopcomputer")
                    Text(quickKey == nil ? "Use any available action here. Long-press a controller key to change its assignment." : "Choose the action for quick key \((quickKey ?? 0) + 1). Your six chat slots stay as they are.").font(.subheadline).foregroundStyle(.secondary)
                    if let reason = store.providerInfo?.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if quickKey == nil, store.providerInfo?.supports("menuNavigation") == true {
                        Button { ControllerSound.shared.keyClick(); store.requestedPanel = "navigate"; dismiss() } label: { Label("Navigate an open menu or files", systemImage: "cursorarrow.motionlines") }
                    }
                }
                ActionCatalogSections(store: store, query: query, executing: quickKey == nil) { action in
                    let dictation = quickKey == nil && action.id == "dictate"
                    let stoppingDictation = dictation && store.isRecording
                    if dictation && !stoppingDictation {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    Task {
                        saving = true; defer { saving = false }
                        let success: Bool
                        if let quickKey { success = await store.saveQuickAction(quickKey, actionID: action.id) }
                        else { success = await store.runAction(action.id) }
                        if stoppingDictation && success { ControllerSound.shared.keyClick() }
                        if success { dismiss() }
                    }
                }
            }.disabled(saving)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search actions, menus, and panels")
                .navigationTitle(quickKey.map { "Map quick key \($0 + 1)" } ?? "\(store.selectedProvider.name) actions")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { ControllerSound.shared.keyClick(); dismiss() } } }
                .alert("Controller update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                    Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil }
                } message: { Text(store.lastError ?? "") }
        }
    }
}

struct MenuNavigationScreen: View {
    @ObservedObject var store: ControllerStore
    @Environment(\.dismiss) private var dismiss
    private var enabled: Bool { store.navigation.active && !store.isBusy }
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("\(store.selectedHost?.name ?? "Mac") · \(store.selectedProvider.name)").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    Image(systemName: store.navigation.active ? "cursorarrow.motionlines" : "macwindow").font(.largeTitle)
                    Text(store.navigation.label).font(.title3.bold()).multilineTextAlignment(.center)
                    if let selection = store.navigation.selection { Text(selection).font(.headline).multilineTextAlignment(.center) }
                }.frame(maxWidth: .infinity, minHeight: 160).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 22))
                HStack(spacing: 18) {
                    control("Previous", icon: "chevron.up", action: "menuPrevious")
                    control("Next", icon: "chevron.down", action: "menuNext")
                }
                control("Select", icon: "checkmark", action: "menuSelect").buttonStyle(.borderedProminent)
                HStack(spacing: 18) {
                    control("Back", icon: "arrow.uturn.backward", action: "menuBack")
                    Button { ControllerSound.shared.keyClick(); Task { await store.navigate("menuHome"); if !store.navigation.active { store.returnHome(); dismiss() } } } label: {
                        Label("Close menus", systemImage: "house").frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(!enabled)
                }
                Text("These controls follow the menu or file picker open on your Mac. Photos library thumbnails still require the Mac’s mouse.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }.padding(22).buttonStyle(.bordered).navigationTitle("Navigate")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { ControllerSound.shared.keyClick(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { ControllerSound.shared.keyClick(); Task { await store.refreshNavigation() } } label: { Image(systemName: "arrow.clockwise") } }
                }
                .task {
                    while !Task.isCancelled { await store.refreshNavigation(); try? await Task.sleep(nanoseconds: 1_000_000_000) }
                }
                .alert("Navigation update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                    Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil }
                } message: { Text(store.lastError ?? "") }
        }
    }
    private func control(_ title: String, icon: String, action: String) -> some View {
        // Previous and Next stay live while the Mac answers; the store queues them.
        let waits = ["menuPrevious", "menuNext"].contains(action)
        return Button { ControllerSound.shared.keyClick(); Task { await store.navigate(action) } } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44) }
            .disabled(waits ? !store.navigation.active : !enabled)
    }
}
