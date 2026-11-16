import SwiftUI
import UIKit

enum GenesisPalette {
    static let hex: [UInt32] = [0x3478F6, 0x9B5CF6, 0xF0529C, 0xFF9933, 0x30C778, 0x29C4DE]
    static func color(_ index: Int) -> Color {
        let h = hex[max(0, min(5, index))]
        return Color(red: Double((h >> 16) & 255)/255, green: Double((h >> 8) & 255)/255, blue: Double(h & 255)/255)
    }
    static let ink = Color(red: 0.15, green: 0.17, blue: 0.20)
}

struct ControllerScreen: View {
    @ObservedObject var store: ControllerStore
    @State private var showSettings = false
    @State private var showArtifacts = false
    @State private var showActions = false
    @State private var showNavigation = false
    @State private var quickMappingIndex: Int?
    @State private var mappingIndex: Int?
    @State private var dialSlot: Int?
    @State private var heldTalk = false
    @GestureState private var talkGestureActive = false
    @State private var talkGestureID: UUID?
    @State private var talkStopTask: Task<Void, Never>?
    @State private var blockedTalkReason: String?
    @State private var artifactID: String?
    @State private var dialArtifactPreview: ArtifactRecord?
    @State private var resolvingSend = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var browsedSlot: Int { dialSlot ?? store.selectedSlotIndex ?? 0 }
    private var slotColor: Color { GenesisPalette.color(store.selectedSlotIndex ?? browsedSlot) }
    private var artifactIndex: Int { store.artifacts.firstIndex { $0.id == artifactID } ?? 0 }
    private var artifactSelectionLabel: String {
        guard store.artifacts.indices.contains(artifactIndex) else { return "No artifacts" }
        return store.artifacts[artifactIndex].title
    }
    private var providerName: String { store.selectedProvider.rawValue == "codex" ? "Codex" : store.selectedProvider.rawValue.capitalized }
    private var codexDraftOnly: Bool { store.selectedProvider == .codex && store.providerInfo?.supports("sendPrompt") != true }
    private var codexQueuesPrompt: Bool { store.selectedProvider == .codex && store.providerInfo?.supports("sendPrompt") == true }
    private var slotPrefix: String { store.selectedProvider == .claude ? "C" : store.selectedProvider == .muse ? "M" : "A" }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                controllerLayout(in: geometry.size)
            }
            .background(Color(red: 0.94, green: 0.95, blue: 0.96).ignoresSafeArea())
            .foregroundStyle(GenesisPalette.ink)
        }
        .sheet(isPresented: $showSettings) { SettingsScreen(store: store) }
        .sheet(isPresented: $showArtifacts) { ArtifactShelf(store: store, initialIndex: artifactIndex) }
        .sheet(item: $dialArtifactPreview) { ArtifactPreview(store: store, artifact: $0) }
        .sheet(isPresented: $showActions, onDismiss: routeRequestedPanel) { ActionBrowser(store:store) }
        .sheet(isPresented: $showNavigation) { MenuNavigationScreen(store:store) }
        .sheet(item: Binding(get: { quickMappingIndex.map { MappingSelection(id:$0) } }, set: { quickMappingIndex = $0?.id })) { selection in
            ActionBrowser(store:store,quickKey:selection.id)
        }
        .sheet(item: Binding(get: { mappingIndex.map { MappingSelection(id: $0) } }, set: { mappingIndex = $0?.id })) { selection in
            MappingScreen(store: store, index: selection.id)
        }
        .alert("Controller update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
        .onChange(of: talkGestureActive) { _, active in
            // onEnded is not called when the system cancels a touch.
            if !active { finishTalkGesture() }
        }
        .onAppear { [store] in
            ControllerSound.shared.captureIsActive = { [weak store] in
                store?.isRecording == true || store?.isFinalizing == true
            }
        }
        .onDisappear { finishTalkGesture() }
        .onChange(of: store.selectedProvider) { _, _ in clearPresentation() }
        .onChange(of: store.selectedHostID) { _, _ in clearPresentation() }
        .onChange(of: store.selectedChat?.id) { _, _ in artifactID = nil }
        .onChange(of: store.requestedPanel) { _, panel in
            if !showActions { routeRequestedPanel() }
        }
        .confirmationDialog("Check this exact chat on your Mac first", isPresented: $resolvingSend, titleVisibility: .visible) {
            Button("I checked — the prompt arrived") { ControllerSound.shared.keyClick(); store.acknowledgeUncertainSend(wasSent: true) }
            Button("I checked — it did not arrive") { ControllerSound.shared.keyClick(); store.acknowledgeUncertainSend(wasSent: false) }
            Button("Keep waiting", role: .cancel) { ControllerSound.shared.keyClick() }
        } message: { Text("This only resolves the saved receipt. Nothing is sent by choosing an answer.") }
    }

    @ViewBuilder
    private func controllerLayout(in size: CGSize) -> some View {
        let sidePadding: CGFloat = isPad && size.width >= 700 ? 28 : 16
        let sideBySide = isPad && size.width >= 930 && size.width > size.height && !dynamicTypeSize.isAccessibilitySize
        if sideBySide {
            let gap: CGFloat = 28
            let availableWidth = size.width - sidePadding * 2
            let panelWidth = min(400, max(300, availableWidth * 0.34))
            let deckSize = min(780, availableWidth - panelWidth - gap, max(480, size.height - 48))
            HStack(alignment: .top, spacing: gap) {
                deck(size: deckSize)
                    .accessibilitySortPriority(0)
                VStack(spacing: 20) {
                    controllerContext
                    controllerControls
                }
                .frame(width: panelWidth)
                .padding(.top, 12)
                .accessibilitySortPriority(1)
            }
            .padding(.horizontal, sidePadding)
            .padding(.vertical, 24)
            .frame(minHeight: size.height)
            .frame(maxWidth: .infinity)
        } else {
            let maxDeckSize: CGFloat = isPad ? 800 : 430
            let deckSize = max(0, min(size.width - sidePadding * 2, maxDeckSize))
            VStack(spacing: isPad ? 20 : 18) {
                controllerContext
                deck(size: deckSize)
                controllerControls
            }
            .padding(.horizontal, sidePadding)
            .padding(.top, isPad ? 24 : 14)
            .padding(.bottom, 24)
            .frame(maxWidth: isPad ? maxDeckSize + sidePadding * 2 : 500)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var controllerContext: some View {
        header
        switches
        connection
    }

    @ViewBuilder
    private var controllerControls: some View {
        actionAccess
        if let summary = store.dictationControl.summary, let reason = store.dictationControl.explanation {
            Button { ControllerSound.shared.keyClick(); store.lastError = reason } label: {
                Label(summary, systemImage: "info.circle")
                    .font(isPad ? .subheadline : .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
        composer
        GlassesFollowPanel(store: store, follow: store.glasses)
        if let receipt = store.lastReceipt {
            Label(receipt.message, systemImage: receipt.statusIcon)
                .font(isPad ? .subheadline : .caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = receipt.deliveryNote {
                Text(note).font(isPad ? .caption : .caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if store.isDemo {
            Text("DESIGN PREVIEW · Sample chats · No commands sent")
                .font(.system(size: isPad ? 12 : 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func clearPresentation() {
        dialSlot = nil; artifactID = nil; heldTalk = false; talkGestureID = nil; blockedTalkReason = nil
        showArtifacts = false; mappingIndex = nil; resolvingSend = false
        showActions = false; showNavigation = false; quickMappingIndex = nil; store.requestedPanel = nil
    }
    private func routeRequestedPanel() {
        if store.requestedPanel == "artifacts" { showArtifacts = true }
        if store.requestedPanel == "navigate" { showNavigation = true }
        store.requestedPanel = nil
    }
    private var actionAccess: some View {
        HStack(spacing: 8) {
            Button { ControllerSound.shared.keyClick(); Task { await store.runAction("previousControllerChat") } } label: { Label("Previous", systemImage:"arrow.left") }
                .disabled(!store.canRunAction("previousControllerChat"))
            if store.availableActions.contains(where: { $0.id == "newChat" }) {
                Button { ControllerSound.shared.keyClick(); Task { await store.runAction("newChat") } } label: { Label("New chat", systemImage:"square.and.pencil") }
                    .disabled(!store.canRunAction("newChat"))
            }
            Spacer(minLength: 0)
            Button { ControllerSound.shared.keyClick(); showActions = true } label: { Label("Actions", systemImage:"square.grid.2x2") }
        }.font(.system(size: isPad ? 14 : 12, weight: .semibold)).buttonStyle(.bordered).controlSize(isPad ? .regular : .small)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GENESIS").font(.system(size: isPad ? 14 : 12, weight: .black, design: .rounded)).tracking(4)
                Text("Agent Micro Controller").font(.system(size: isPad ? 28 : 22, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 4)
            Button { ControllerSound.shared.keyClick(); showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: isPad ? 21 : 18)).frame(width: isPad ? 52 : 44, height: isPad ? 52 : 44)
                    .background(.white.opacity(0.8), in: Circle())
            }.accessibilityLabel("Settings and Mac pairing")
        }
    }

    private var switches: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                if store.hosts.isEmpty {
                    Button { ControllerSound.shared.keyClick(); showSettings = true } label: {
                        Label("Pair a Mac", systemImage: "plus.circle")
                            .font(.system(size: isPad ? 14 : 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: isPad ? 48 : 42)
                            .background(.white, in: RoundedRectangle(cornerRadius: 13))
                    }
                }
                ForEach(store.hosts) { host in
                    Button { ControllerSound.shared.keyClick(); store.selectHost(host.id) } label: {
                        Label(host.name, systemImage: host.name.lowercased().contains("neo") ? "laptopcomputer" : "macmini")
                            .font(.system(size: isPad ? 14 : 12, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: isPad ? 48 : 42)
                            .background(store.selectedHostID == host.id ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                    }.accessibilityAddTraits(store.selectedHostID == host.id ? .isSelected : [])
                }
            }.padding(4).background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
            HStack(spacing: 6) {
                ForEach([ProviderID.codex, .claude, .muse], id: \.rawValue) { provider in
                    Button { ControllerSound.shared.keyClick(); store.selectProvider(provider) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: provider == .codex ? "terminal" : provider == .claude ? "sun.max" : "sparkle")
                            Text(provider == .codex ? "Codex" : provider.rawValue.capitalized)
                        }.font(.system(size: isPad ? 15 : 13, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: isPad ? 48 : 42)
                            .foregroundStyle(store.selectedProvider == provider ? Color.white : GenesisPalette.ink)
                            .background(store.selectedProvider == provider ? GenesisPalette.ink : Color.white.opacity(0.65), in: Capsule())
                    }.accessibilityAddTraits(store.selectedProvider == provider ? .isSelected : [])
                }
            }
        }
    }

    private var connection: some View {
        HStack(spacing: 8) {
            Circle().fill(store.providerInfo?.readiness == "ready" ? Color.green : Color.orange).frame(width: isPad ? 8 : 6, height: isPad ? 8 : 6)
            Text(store.connectionMessage).font(.system(size: isPad ? 14 : 11, weight: .medium)).lineLimit(1)
            Spacer()
            if store.isBusy { ProgressView().controlSize(.mini) }
            Button { ControllerSound.shared.keyClick(); Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: isPad ? 44 : 32, height: isPad ? 44 : 30) }
                .accessibilityLabel("Refresh connection and chats")
        }.foregroundStyle(.secondary).padding(.horizontal, 7)
    }

    private func slotTitle(_ index: Int) -> String {
        guard let mapping = store.profile.slots.first(where: { $0.index == index }), mapping.kind != "empty", !mapping.title.isEmpty else {
            return "Assign"
        }
        return mapping.title
    }

    private func activateSlot(_ index: Int) {
        guard !store.isBusy else { return }
        dialSlot = index
        let selectedMapping = store.profile.slots.first { $0.index == index }
        let dictationAction = selectedMapping?.kind == "action" && selectedMapping?.targetID == "dictate"
        let stoppingDictation = dictationAction && store.isRecording
        if dictationAction { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        else { ControllerSound.shared.keyClick() }
        guard let mapping = store.profile.slots.first(where: { $0.index == index }), mapping.kind != "empty" else {
            mappingIndex = index
            return
        }
        let hostID = store.selectedHostID
        let provider = store.selectedProvider
        Task {
            guard store.selectedHostID == hostID, store.selectedProvider == provider,
                  let current = store.profile.slots.first(where: { $0.index == index }),
                  current.kind == mapping.kind, current.targetID == mapping.targetID else { return }
            await store.openSlot(index)
            if stoppingDictation { ControllerSound.shared.keyClick() }
            if mapping.kind == "chat", store.selectedSlotIndex == index, dialSlot == index,
               store.selectedHostID == hostID, store.selectedProvider == provider {
                dialSlot = nil
            }
        }
    }

    private func turnArtifactDial(_ delta: Int) {
        guard !store.artifacts.isEmpty else {
            artifactID = nil
            return
        }
        let count = store.artifacts.count
        let next = ((artifactIndex + delta) % count + count) % count
        artifactID = store.artifacts[next].id
    }

    private func deck(size: CGFloat) -> some View {
        let scale = isPad ? max(1, size / 430) : 1
        let gap: CGFloat = 8 * scale
        let inner = size * 0.74
        let key = max(0, (inner - gap * 3) / 4)
        return ZStack {
            if let artwork = UIImage(named: "ControllerShell") {
                Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 38).fill(.white).overlay(RoundedRectangle(cornerRadius: 38).stroke(.white, lineWidth: 8))
                    .shadow(color: .black.opacity(0.12), radius: 20, y: 12)
            }
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    DialControl(silver: true, caption: "CHATS", color: GenesisPalette.color(browsedSlot), scale: scale,
                                selectionDescription: "\(slotPrefix)\(browsedSlot + 1), \(slotTitle(browsedSlot))", turn: { delta in
                        dialSlot = ((browsedSlot + delta) % 6 + 6) % 6
                    }, press: { activateSlot(browsedSlot) }).frame(width: key, height: key)
                    slot(0, size: key, scale: scale)
                    slot(1, size: key, scale: scale)
                    DialControl(silver: false, caption: "ARTIFACTS", color: slotColor, scale: scale,
                                selectionDescription: artifactSelectionLabel,
                                visibleSelection: artifactID.flatMap { id in store.artifacts.first { $0.id == id }?.title },
                                turn: turnArtifactDial, press: {
                        ControllerSound.shared.keyClick()
                        if let artifactID, let artifact = store.artifacts.first(where: { $0.id == artifactID }) {
                            dialArtifactPreview = artifact
                        } else {
                            showArtifacts = true
                        }
                    }).frame(width: key, height: key)
                }
                HStack(spacing: gap) { ForEach(2..<6) { slot($0, size: key, scale: scale) } }
                HStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { index in quickActionKey(index, size: key, scale: scale) }
                }
                HStack(spacing: gap) {
                    Button { ControllerSound.shared.keyClick(); dialSlot = nil; store.returnHome() } label: {
                        VStack(spacing: 4 * scale) {
                            PixelLight(color: slotColor, working: store.isBusy, reduceMotion: reduceMotion, scale: scale)
                                .frame(width: 26 * scale, height: 26 * scale)
                            Text("HOME").font(.system(size: 8 * scale, weight: .bold, design: .monospaced))
                        }
                            .frame(width: key, height: key * 0.9)
                    }.accessibilityLabel("Return to chat selection")
                    talkKey(width: key * 2 + gap, height: key * 0.9, scale: scale)
                    actionKey("Map", icon: "slider.horizontal.3", size: key, scale: scale, enabled: true) { mappingIndex = browsedSlot }
                        .frame(height: key * 0.9)
                }
            }.frame(width: inner)
        }.frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                Text("YOUR AGENTS. ONE PLACE.").font(.system(size: 7 * scale, weight: .semibold, design: .monospaced)).tracking(1.4 * scale)
                    .foregroundStyle(.secondary).padding(.bottom, 24 * scale)
            }
    }

    private func slot(_ index: Int, size: CGFloat, scale: CGFloat) -> some View {
        let title = slotTitle(index)
        let selected = store.selectedSlotIndex == index
        let browsed = browsedSlot == index
        let color = GenesisPalette.color(index)
        let assigned = store.profile.slots.contains { $0.index == index && $0.kind != "empty" }
        return ZStack {
            KeySurface(color: color, illuminated: selected, scale: scale, tinted: assigned)
            VStack(spacing: 5 * scale) {
                HStack(spacing: 4 * scale) {
                    Circle().fill(color.opacity(assigned ? 1 : 0.45))
                        .frame(width: 7 * scale, height: 7 * scale)
                        .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 0.6 * scale))
                    Text("\(slotPrefix)\(index + 1)")
                        .font(.system(size: 11 * scale, weight: .bold, design: .monospaced))
                }
                Text(title)
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(width: max(0, size - 12 * scale), height: 22 * scale, alignment: .top)
            }
            .foregroundStyle(GenesisPalette.ink)
            .padding(.vertical, 5 * scale)
        }.frame(width: size, height: size)
            .overlay {
                if browsed {
                    RoundedRectangle(cornerRadius: 15 * scale)
                        .strokeBorder(GenesisPalette.ink.opacity(0.65), style: StrokeStyle(lineWidth: 1.3 * scale, dash: [3 * scale, 2.5 * scale]))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 15 * scale))
            .gesture(LongPressGesture(minimumDuration: 0.65).exclusively(before: TapGesture()).onEnded { value in
                switch value { case .first: ControllerSound.shared.keyClick(); mappingIndex = index
                case .second: activateSlot(index) }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(slotPrefix)\(index + 1), \(title)")
            .accessibilityValue(selected && browsed ? "Current chat, dial selection" : selected ? "Current chat" : browsed ? "Dial selection" : "")
            .accessibilityAction { activateSlot(index) }
            .accessibilityAction(named: "Change assignment") { ControllerSound.shared.keyClick(); mappingIndex = index }
    }

    private func actionKey(_ title: String, icon: String, size: CGFloat, scale: CGFloat, active: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { ControllerSound.shared.keyClick(); action() } label: {
            ZStack {
                KeySurface(color: slotColor, illuminated: active, scale: scale)
                VStack(spacing: 7 * scale) {
                    Image(systemName: icon).font(.system(size: 18 * scale, weight: .medium))
                    Text(title.uppercased()).font(.system(size: 8.5 * scale, weight: .semibold, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail).frame(width: max(0, size - 14 * scale))
                }.opacity(enabled ? 1 : 0.48)
            }.frame(width: size, height: size)
        }.buttonStyle(KeyPressStyle()).disabled(!enabled).accessibilityLabel(title)
    }
    private func quickActionKey(_ index: Int, size: CGFloat, scale: CGFloat) -> some View {
        let id = store.profile.quickActionIDs[index]
        let action = store.action(id)
        let titles = ["sendPrompt":"Send", "stop":"Stop", "nativeVoice":"Voice", "artifacts":"Artifacts", "modelAndEffort":"Model"]
        let title = titles[id] ?? action?.title ?? "Unavailable"
        let enabled = store.canRunAction(id)
        return ZStack {
            KeySurface(color:slotColor,illuminated:id == "sendPrompt" && store.sendReady && enabled, scale: scale)
            VStack(spacing: 7 * scale) {
                Image(systemName:action?.icon ?? "questionmark").font(.system(size: 18 * scale, weight:.medium))
                Text(title.uppercased())
                    .font(.system(size: 8.5 * scale, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(width: max(0, size - 14 * scale))
            }.opacity(enabled ? 1 : 0.48)
        }.frame(width:size,height:size).contentShape(RoundedRectangle(cornerRadius:15 * scale))
            .gesture(LongPressGesture(minimumDuration:0.65).exclusively(before:TapGesture()).onEnded { value in
                switch value {
                case .first: ControllerSound.shared.keyClick(); quickMappingIndex = index
                case .second:
                    runQuickAction(id)
                }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton).accessibilityLabel(title)
            .accessibilityHint(enabled ? "Tap to run. Hold to change this action." : store.actionUnavailableReason(id) ?? "This action is not available.")
            .accessibilityAction { runQuickAction(id) }
            .accessibilityAction(named:"Change action") { ControllerSound.shared.keyClick(); quickMappingIndex = index }
    }

    private func runQuickAction(_ id: String) {
        let dictationAction = id == "dictate"
        let stoppingDictation = dictationAction && store.isRecording
        if dictationAction { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        else { ControllerSound.shared.keyClick() }
        guard store.canRunAction(id) else {
            store.lastError = store.actionUnavailableReason(id) ?? "This action is not available."
            return
        }
        Task {
            await store.runAction(id)
            if stoppingDictation { ControllerSound.shared.keyClick() }
        }
    }

    private func finishTalkGesture() {
        let reason = blockedTalkReason
        blockedTalkReason = nil
        guard heldTalk else {
            if let reason { store.lastError = reason }
            return
        }
        heldTalk = false
        let host = store.selectedHostID
        let provider = store.selectedProvider
        let chat = store.selectedChat?.id
        talkStopTask = Task {
            // Switching context already cancels capture in the store. An old
            // release must not stop a new chat's independently started capture.
            guard store.selectedHostID == host, store.selectedProvider == provider,
                  store.selectedChat?.id == chat else { return }
            await store.stopDictation()
            ControllerSound.shared.keyClick()
        }
    }

    private func talkKey(width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        ZStack {
            FrostedControlSurface(color: slotColor, illuminated: store.isRecording, scale: scale)
                .overlay(RoundedRectangle(cornerRadius: 15 * scale).strokeBorder(store.isRecording ? slotColor.opacity(0.65) : .clear, lineWidth: 1.5 * scale))
            VStack(spacing: 5 * scale) {
                Image(systemName: store.dictationControl.icon).font(.system(size: 23 * scale, weight: .medium))
                Text(store.dictationControl.label)
                    .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail).frame(width: max(0, width - 14 * scale))
            }.foregroundStyle(store.isRecording ? slotColor : GenesisPalette.ink).opacity(store.canDictate ? 1 : 0.35)
        }.frame(width: width, height: height).contentShape(RoundedRectangle(cornerRadius: 16 * scale))
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .updating($talkGestureActive) { _, active, _ in active = true }
                .onChanged { _ in
                guard !heldTalk, blockedTalkReason == nil else { return }
                guard store.canDictate else { blockedTalkReason = store.dictationControl.explanation; return }
                heldTalk = true
                let gestureID = UUID()
                talkGestureID = gestureID
                let previousStop = talkStopTask
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                Task {
                    await previousStop?.value
                    guard heldTalk, talkGestureID == gestureID else { return }
                    await store.startDictation()
                }
            }.onEnded { _ in finishTalkGesture() })
            .accessibilityElement(children: .ignore).accessibilityLabel(store.dictationControl.accessibilityLabel)
            .accessibilityHint(store.dictationControl.explanation ?? "Hold to record, then release to review your draft.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if store.isRecording { Task { await store.stopDictation(); ControllerSound.shared.keyClick() } }
                else if store.canDictate {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    Task { await store.startDictation() }
                }
                else { ControllerSound.shared.keyClick(); store.lastError = store.dictationControl.explanation }
            }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: isPad ? 12 : 9) {
            HStack {
                Circle().fill(slotColor).frame(width: 7, height: 7)
                Text(store.selectedChat?.title ?? "Choose a chat to begin").font(.system(size: isPad ? 17 : 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(providerName).font(isPad ? .caption : .caption2).foregroundStyle(.secondary)
            }
            TextField(codexDraftOnly ? "Local draft — Send is not connected yet" : "Hold the microphone, or type a draft…", text: $store.draft, axis: .vertical)
                .font(.system(size: isPad ? 17 : 14)).lineLimit(isPad ? 3...8 : 2...5).disabled(store.selectedChat == nil || store.isRecording || store.isFinalizing)
                .accessibilityLabel("Draft for selected chat")
            HStack {
                Text(codexDraftOnly ? (store.isRecording ? "Listening on iPhone · draft only" : "Saved on iPhone · Send is not available for \(providerName) yet") : store.isRecording ? "Listening on iPhone" : codexQueuesPrompt ? "Send queues this draft for the selected Codex chat" : "Only sent when you press Send")
                    .font(.system(size: isPad ? 13 : 10)).foregroundStyle(.secondary)
                Spacer()
                if store.sendReady && store.providerInfo?.supports("sendPrompt") == true { Label(codexQueuesPrompt ? "Ready to queue" : "Ready to send", systemImage: "arrow.up.circle.fill").font(.system(size: isPad ? 13 : 10, weight: .semibold)).foregroundStyle(slotColor) }
            }
            if store.navigationOnly {
                Text("Chat switching, available menu controls, and artifacts still work.")
                    .font(isPad ? .subheadline : .caption).foregroundStyle(.secondary)
            }
            if store.hasUnresolvedSend {
                Text("Delivery is unconfirmed. Your draft is saved and won’t be resent automatically.")
                    .font(isPad ? .subheadline : .caption).foregroundStyle(.orange)
                HStack {
                    Button("Check receipt") { ControllerSound.shared.keyClick(); Task { await store.recoverPendingSend() } }
                    Spacer()
                    Button("I checked the Mac…") { ControllerSound.shared.keyClick(); resolvingSend = true }
                }.font(isPad ? .subheadline : .caption)
            }
        }.padding(isPad ? 20 : 16).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct MappingSelection: Identifiable { let id: Int }

/// Native frost and light sit beneath the reused Blender bevels. Keeping the
/// light separate from labels preserves contrast and the fixed slot palette.
private struct FrostedControlSurface: View {
    var color: Color = .clear
    var illuminated = false
    var scale: CGFloat = 1
    var tinted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 15 * scale, style: .continuous) }
    private var light: Double { illuminated ? 0.54 : tinted ? 0.28 : 0 }

    var body: some View {
        ZStack {
            shape.fill(Color(white: 0.86))
                .shadow(color: .black.opacity(0.14), radius: 2 * scale, x: 0, y: 3 * scale)
                .shadow(color: color.opacity(illuminated ? 0.32 : tinted ? 0.10 : 0), radius: 8 * scale, x: 0, y: 1 * scale)
            if reduceTransparency {
                shape.fill(Color(white: 0.97))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(.white.opacity(0.35))
            }
            shape.fill(RadialGradient(colors: [color.opacity(light), color.opacity(light * 0.24), .clear],
                                      center: .bottom, startRadius: 0, endRadius: 68 * scale))
            shape.fill(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.10), .clear],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35), color.opacity(tinted || illuminated ? 0.30 : 0.10)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2 * scale)
            shape.inset(by: 2.5 * scale).strokeBorder(.white.opacity(0.35), lineWidth: 0.6 * scale)
            if contrast == .increased {
                shape.strokeBorder(GenesisPalette.ink.opacity(0.6), lineWidth: 1.2 * scale)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: illuminated)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct KeySurface: View {
    var color: Color = .clear
    var illuminated = false
    var scale: CGFloat = 1
    var tinted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            FrostedControlSurface(color: color, illuminated: illuminated, scale: scale, tinted: tinted)
            if let artwork = UIImage(named: "ControllerKey") {
                Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit()
                    .scaleEffect(1.15).opacity(reduceTransparency ? 0.36 : 0.22)
                    .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 15 * scale).strokeBorder(color.opacity(illuminated ? 0.58 : 0), lineWidth: 1.4 * scale))
        .accessibilityHidden(true)
    }
}

struct KeyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DialControl: View {
    let silver: Bool
    let caption: String
    let color: Color
    var scale: CGFloat = 1
    var selectionDescription: String = ""
    var visibleSelection: String?
    let turn: (Int) -> Void
    let press: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var isDragging = false
    @State private var tracking: DialTracking?
    @State private var restingRotation = 0.0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    face.rotationEffect(.degrees(restingRotation + (tracking?.degrees ?? 0)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(drag(in: size).exclusively(before: TapGesture()).onEnded { gesture in
                    switch gesture {
                    case .first(let value):
                        updateDrag(value, in: size)
                        finishDrag()
                    case .second:
                        pressDial()
                    }
                })
            }
            Text(visibleSelection ?? caption)
                .font(.system(size: 7 * scale, weight: .semibold, design: .monospaced))
                .tracking(0.6 * scale)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
        .onChange(of: isDragging) { _, active in if !active { finishDrag() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(silver ? "Chat dial" : "Artifact dial")
        .accessibilityValue(selectionDescription)
        .accessibilityHint(silver ? "Adjust to browse chats. Activate to open the highlighted key." : "Adjust to browse artifacts. Activate to open the selection or shelf.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 1)
            case .decrement: adjust(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction { pressDial() }
    }

    @ViewBuilder private var face: some View {
        if silver {
            // A quiet, slow illumination cycle runs only while this screen is
            // active. Rotation remains driven by the existing finger tracking.
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: scenePhase != .active || reduceMotion)) { context in
                let breath = reduceMotion || scenePhase != .active ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * .pi / 2.8) + 1) / 2
                frostedFace(breath: breath)
            }
        } else if let artwork = UIImage(named: "ControllerDial") {
            Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit()
        } else {
            ZStack {
                Circle().fill(GenesisPalette.ink).padding(3 * scale)
                Capsule().fill(.white.opacity(0.8))
                    .frame(width: 3 * scale, height: 12 * scale).offset(y: -17 * scale)
            }
        }
    }

    private func frostedFace(breath: Double) -> some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height) * 0.82
            ZStack {
                Circle().fill(color.opacity(0.17 + breath * 0.07))
                    .blur(radius: 5 * scale).padding(-2 * scale)
                Circle().fill(Color(white: reduceTransparency ? 0.97 : 0.91))
                    .shadow(color: .black.opacity(0.16), radius: 2 * scale, y: 2 * scale)
                Circle().fill(RadialGradient(colors: [color.opacity(0.44 + breath * 0.09), color.opacity(0.18), .white.opacity(0.30)],
                                             center: .bottomTrailing, startRadius: 0, endRadius: diameter * 0.85))
                Circle().fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.3 * scale)
                Circle().inset(by: 2 * scale).strokeBorder(color.opacity(0.22), lineWidth: 0.6 * scale)
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                if let artwork = UIImage(named: "ControllerDialSilver") {
                    Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit()
                        .frame(width: diameter / 0.82, height: diameter / 0.82)
                        .opacity(reduceTransparency ? 0.58 : 0.38)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: color)
    }

    private func drag(in size: CGSize) -> some Gesture<DragGesture.Value> {
        DragGesture(minimumDistance: 6 * scale)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { updateDrag($0, in: size) }
    }

    private func updateDrag(_ value: DragGesture.Value, in size: CGSize) {
        var current = tracking ?? DialTracking(start: value.startLocation,
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            radius: min(size.width, size.height) / 2)
        let change = current.move(to: value.location)
        tracking = current
        if change != 0 {
            ControllerSound.shared.dialTick()
            turn(change)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func finishDrag() {
        guard let tracking else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            restingRotation += Double(tracking.steps) * DialTracking.degreesPerStep
            self.tracking = nil
        }
    }

    private func pressDial() {
        // The destination owns feedback so mapped microphone actions start
        // with haptics only, including activation from the chat dial.
        press()
    }

    private func adjust(by steps: Int) {
        ControllerSound.shared.dialTick()
        turn(steps)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            restingRotation += Double(steps) * DialTracking.degreesPerStep
        }
    }
}

struct PixelLight: View {
    let color: Color
    let working: Bool
    let reduceMotion: Bool
    var scale: CGFloat = 1
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !working || reduceMotion)) { context in
            let phase = Int(context.date.timeIntervalSince1970 * 4) % 12
            VStack(spacing: 2 * scale) {
                ForEach(0..<5) { row in HStack(spacing: 2 * scale) {
                    ForEach(0..<5) { column in
                        let i = row * 5 + column
                        let lit = working ? ((i + phase) % 7 < 2) : [11, 12, 13].contains(i)
                        Circle().fill(color.opacity(lit ? 0.9 : 0.12)).frame(width: 4 * scale, height: 4 * scale)
                    }
                }
                }
            }
        }.accessibilityHidden(true)
    }
}
