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
    @State private var dialSlot = 0
    @State private var heldTalk = false
    @State private var blockedTalkReason: String?
    @State private var artifactIndex = 0
    @State private var resolvingSend = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slotColor: Color { GenesisPalette.color(store.selectedSlotIndex ?? dialSlot) }
    private var providerName: String { store.selectedProvider.rawValue == "codex" ? "Codex" : store.selectedProvider.rawValue.capitalized }
    private var codexDraftOnly: Bool { store.selectedProvider == .codex && store.providerInfo?.supports("sendPrompt") != true }
    private var codexQueuesPrompt: Bool { store.selectedProvider == .codex && store.providerInfo?.supports("sendPrompt") == true }
    private var slotPrefix: String { store.selectedProvider == .claude ? "C" : store.selectedProvider == .muse ? "M" : "A" }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    header
                    switches
                    connection
                    deck(size: min(geometry.size.width - 32, 430))
                    actionAccess
                    if let summary = store.dictationControl.summary, let reason = store.dictationControl.explanation {
                        Button { store.lastError = reason } label: {
                            Label(summary, systemImage:"info.circle").font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                        }.foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                    composer
                    if let receipt = store.lastReceipt {
                        Label(receipt.message, systemImage: receipt.statusIcon)
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if let note = receipt.deliveryNote {
                            Text(note).font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                    if store.isDemo {
                        Text("DESIGN PREVIEW · Sample chats · No commands sent")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 24)
                .frame(maxWidth: 500).frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.94, green: 0.95, blue: 0.96).ignoresSafeArea())
            .foregroundStyle(GenesisPalette.ink)
        }
        .sheet(isPresented: $showSettings) { SettingsScreen(store: store) }
        .sheet(isPresented: $showArtifacts) { ArtifactShelf(store: store, initialIndex: artifactIndex) }
        .sheet(isPresented: $showActions, onDismiss: routeRequestedPanel) { ActionBrowser(store:store) }
        .sheet(isPresented: $showNavigation) { MenuNavigationScreen(store:store) }
        .sheet(item: Binding(get: { quickMappingIndex.map { MappingSelection(id:$0) } }, set: { quickMappingIndex = $0?.id })) { selection in
            ActionBrowser(store:store,quickKey:selection.id)
        }
        .sheet(item: Binding(get: { mappingIndex.map { MappingSelection(id: $0) } }, set: { mappingIndex = $0?.id })) { selection in
            MappingScreen(store: store, index: selection.id)
        }
        .alert("Controller update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
        .onChange(of: store.selectedProvider) { _, _ in clearPresentation() }
        .onChange(of: store.selectedHostID) { _, _ in clearPresentation() }
        .onChange(of: store.requestedPanel) { _, panel in
            if !showActions { routeRequestedPanel() }
        }
        .confirmationDialog("Check this exact chat on your Mac first", isPresented: $resolvingSend, titleVisibility: .visible) {
            Button("I checked — the prompt arrived") { store.acknowledgeUncertainSend(wasSent: true) }
            Button("I checked — it did not arrive") { store.acknowledgeUncertainSend(wasSent: false) }
            Button("Keep waiting", role: .cancel) {}
        } message: { Text("This only resolves the saved receipt. Nothing is sent by choosing an answer.") }
    }

    private func clearPresentation() {
        dialSlot = 0; heldTalk = false; blockedTalkReason = nil; showArtifacts = false; mappingIndex = nil; resolvingSend = false
        showActions = false; showNavigation = false; quickMappingIndex = nil; store.requestedPanel = nil
    }
    private func routeRequestedPanel() {
        if store.requestedPanel == "artifacts" { showArtifacts = true }
        if store.requestedPanel == "navigate" { showNavigation = true }
        store.requestedPanel = nil
    }
    private var actionAccess: some View {
        HStack(spacing: 8) {
            Button { Task { await store.runAction("previousControllerChat") } } label: { Label("Previous", systemImage:"arrow.left") }
                .disabled(!store.canRunAction("previousControllerChat"))
            if store.availableActions.contains(where: { $0.id == "newChat" }) {
                Button { Task { await store.runAction("newChat") } } label: { Label("New chat", systemImage:"square.and.pencil") }
                    .disabled(!store.canRunAction("newChat"))
            }
            Spacer(minLength: 0)
            Button { showActions = true } label: { Label("Actions", systemImage:"square.grid.2x2") }
        }.font(.system(size:12,weight:.semibold)).buttonStyle(.bordered).controlSize(.small)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GENESIS").font(.system(size: 12, weight: .black, design: .rounded)).tracking(4)
                Text("Agent Micro Controller").font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 4)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18)).frame(width: 44, height: 44)
                    .background(.white.opacity(0.8), in: Circle())
            }.accessibilityLabel("Settings and Mac pairing")
        }
    }

    private var switches: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(store.hosts) { host in
                    Button { store.selectHost(host.id) } label: {
                        Label(host.name, systemImage: host.name.lowercased().contains("neo") ? "laptopcomputer" : "macmini")
                            .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 42)
                            .background(store.selectedHostID == host.id ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                    }.accessibilityAddTraits(store.selectedHostID == host.id ? .isSelected : [])
                }
            }.padding(4).background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
            HStack(spacing: 6) {
                ForEach([ProviderID.codex, .claude, .muse], id: \.rawValue) { provider in
                    Button { store.selectProvider(provider) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: provider == .codex ? "terminal" : provider == .claude ? "sun.max" : "sparkle")
                            Text(provider == .codex ? "Codex" : provider.rawValue.capitalized)
                        }.font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 42)
                            .foregroundStyle(store.selectedProvider == provider ? Color.white : GenesisPalette.ink)
                            .background(store.selectedProvider == provider ? GenesisPalette.ink : Color.white.opacity(0.65), in: Capsule())
                    }.accessibilityAddTraits(store.selectedProvider == provider ? .isSelected : [])
                }
            }
        }
    }

    private var connection: some View {
        HStack(spacing: 8) {
            Circle().fill(store.providerInfo?.readiness == "ready" ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(store.connectionMessage).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer()
            if store.isBusy { ProgressView().controlSize(.mini) }
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 30) }
                .accessibilityLabel("Refresh connection and chats")
        }.foregroundStyle(.secondary).padding(.horizontal, 7)
    }

    private func deck(size: CGFloat) -> some View {
        let gap: CGFloat = 8
        let inner = size * 0.74
        let key = (inner - gap * 3) / 4
        return ZStack {
            if let artwork = UIImage(named: "ControllerShell") {
                Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 38).fill(.white).overlay(RoundedRectangle(cornerRadius: 38).stroke(.white, lineWidth: 8))
                    .shadow(color: .black.opacity(0.12), radius: 20, y: 12)
            }
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    DialControl(silver: true, caption: "CHATS", color: slotColor, turn: { delta in
                        dialSlot = ((dialSlot + delta) % 6 + 6) % 6
                    }, press: { Task { await store.openSlot(dialSlot) } }).frame(width: key, height: key)
                    slot(0, size: key)
                    slot(1, size: key)
                    DialControl(silver: false, caption: "ARTIFACTS", color: slotColor, turn: { delta in
                        if !store.artifacts.isEmpty { artifactIndex = ((artifactIndex + delta) % store.artifacts.count + store.artifacts.count) % store.artifacts.count }
                    }, press: { showArtifacts = true }).frame(width: key, height: key)
                }
                HStack(spacing: gap) { ForEach(2..<6) { slot($0, size: key) } }
                HStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { index in quickActionKey(index, size:key) }
                }
                HStack(spacing: gap) {
                    Button { store.returnHome() } label: {
                        VStack(spacing: 4) { PixelLight(color: slotColor, working: store.isBusy, reduceMotion: reduceMotion).frame(width: 26, height: 26); Text("HOME").font(.system(size: 8, weight: .bold, design: .monospaced)) }
                            .frame(width: key, height: key * 0.9)
                    }.accessibilityLabel("Return to chat selection")
                    talkKey(width: key * 2 + gap, height: key * 0.9)
                    actionKey("Map", icon: "slider.horizontal.3", size: key, enabled: true) { mappingIndex = store.selectedSlotIndex ?? dialSlot }
                        .frame(height: key * 0.9)
                }
            }.frame(width: inner)
        }.frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                Text("YOUR AGENTS. ONE PLACE.").font(.system(size: 7, weight: .semibold, design: .monospaced)).tracking(1.4)
                    .foregroundStyle(.secondary).padding(.bottom, 24)
            }
    }

    private func slot(_ index: Int, size: CGFloat) -> some View {
        let mapping = store.profile.slots.first { $0.index == index }
        let selected = store.selectedSlotIndex == index
        let color = GenesisPalette.color(index)
        func activateSlot() {
            dialSlot = index
            if mapping?.kind == "empty" || mapping == nil { mappingIndex = index }
            else { Task { await store.openSlot(index) } }
        }
        return ZStack {
            ZStack {
                KeySurface(color: color, illuminated: selected || dialSlot == index)
                VStack(spacing: 4) {
                    Circle().fill(color).frame(width: 12, height: 12).shadow(color: color.opacity(0.6), radius: selected ? 8 : 2)
                    Text("\(slotPrefix)\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(mapping?.kind == "empty" ? "Assign" : mapping?.title ?? "Assign")
                        .font(.system(size: 8, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 5)
                }
            }.frame(width: size, height: size)
        }.contentShape(RoundedRectangle(cornerRadius: 15))
            .gesture(LongPressGesture(minimumDuration: 0.65).exclusively(before: TapGesture()).onEnded { value in
                switch value { case .first: mappingIndex = index; case .second: activateSlot() }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(slotPrefix)\(index + 1), \(mapping?.title ?? "unassigned")")
            .accessibilityAction { activateSlot() }
            .accessibilityAction(named: "Change assignment") { mappingIndex = index }
    }

    private func actionKey(_ title: String, icon: String, size: CGFloat, active: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                KeySurface(color: slotColor, illuminated: active)
                VStack(spacing: 7) {
                    Image(systemName: icon).font(.system(size: 18, weight: .medium))
                    Text(title.uppercased()).font(.system(size: 8, weight: .semibold, design: .monospaced))
                }.opacity(enabled ? 1 : 0.28)
            }.frame(width: size, height: size)
        }.buttonStyle(KeyPressStyle()).disabled(!enabled).accessibilityLabel(title)
    }
    private func quickActionKey(_ index: Int, size: CGFloat) -> some View {
        let id = store.profile.quickActionIDs[index]
        let action = store.action(id)
        let titles = ["sendPrompt":"Send", "stop":"Stop", "nativeVoice":"Voice", "artifacts":"Artifacts"]
        let title = titles[id] ?? action?.title ?? "Unavailable"
        let enabled = store.canRunAction(id)
        return ZStack {
            KeySurface(color:slotColor,illuminated:id == "sendPrompt" && store.sendReady && enabled)
            VStack(spacing:7) {
                Image(systemName:action?.icon ?? "questionmark").font(.system(size:18,weight:.medium))
                Text(title.uppercased()).font(.system(size:8,weight:.semibold,design:.monospaced)).lineLimit(2).minimumScaleFactor(0.65)
            }.opacity(enabled ? 1 : 0.28)
        }.frame(width:size,height:size).contentShape(RoundedRectangle(cornerRadius:15))
            .gesture(LongPressGesture(minimumDuration:0.65).exclusively(before:TapGesture()).onEnded { value in
                switch value {
                case .first: quickMappingIndex = index
                case .second: if enabled { Task { await store.runAction(id) } }
                }
            })
            .accessibilityAddTraits(.isButton).accessibilityLabel(title)
            .accessibilityAction { if enabled { Task { await store.runAction(id) } } }
            .accessibilityAction(named:"Change action") { quickMappingIndex = index }
    }

    private func talkKey(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(store.isRecording ? slotColor.opacity(0.13) : Color.white.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(store.isRecording ? slotColor : Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.09), radius: 3, y: 3)
            VStack(spacing: 5) {
                Image(systemName: store.dictationControl.icon).font(.system(size: 23, weight: .medium))
                Text(store.dictationControl.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
            }.foregroundStyle(store.isRecording ? slotColor : GenesisPalette.ink).opacity(store.canDictate ? 1 : 0.35)
        }.frame(width: width, height: height).contentShape(RoundedRectangle(cornerRadius: 16))
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                guard !heldTalk, blockedTalkReason == nil else { return }
                guard store.canDictate else { blockedTalkReason = store.dictationControl.explanation; return }
                heldTalk = true
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                Task { await store.startDictation() }
            }.onEnded { _ in
                let reason = blockedTalkReason; blockedTalkReason = nil
                if heldTalk { heldTalk = false; Task { await store.stopDictation() } }
                else if let reason { store.lastError = reason }
            })
            .accessibilityElement(children: .ignore).accessibilityLabel(store.dictationControl.accessibilityLabel)
            .accessibilityHint(store.dictationControl.explanation ?? "Hold to record, then release to review your draft.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if store.isRecording { Task { await store.stopDictation() } }
                else if store.canDictate { Task { await store.startDictation() } }
                else { store.lastError = store.dictationControl.explanation }
            }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Circle().fill(slotColor).frame(width: 7, height: 7)
                Text(store.selectedChat?.title ?? "Choose a chat to begin").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(providerName).font(.caption2).foregroundStyle(.secondary)
            }
            TextField(codexDraftOnly ? "Local draft — Send is not connected yet" : "Hold the microphone, or type a draft…", text: $store.draft, axis: .vertical)
                .font(.system(size: 14)).lineLimit(2...5).disabled(store.selectedChat == nil)
                .accessibilityLabel("Draft for selected chat")
            HStack {
                Text(codexDraftOnly ? (store.isRecording ? "Listening on iPhone · draft only" : "Saved on iPhone · Send is not available for \(providerName) yet") : store.isRecording ? "Listening on iPhone" : codexQueuesPrompt ? "Send queues this draft for the selected Codex chat" : "Only sent when you press Send")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if store.sendReady && store.providerInfo?.supports("sendPrompt") == true { Label(codexQueuesPrompt ? "Ready to queue" : "Ready to send", systemImage: "arrow.up.circle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(slotColor) }
            }
            if store.navigationOnly {
                Text("Chat switching, available menu controls, and artifacts still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.hasUnresolvedSend {
                Text("Delivery is unconfirmed. Your draft is saved and won’t be resent automatically.")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    Button("Check receipt") { Task { await store.recoverPendingSend() } }
                    Spacer()
                    Button("I checked the Mac…") { resolvingSend = true }
                }.font(.caption)
            }
        }.padding(16).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct MappingSelection: Identifiable { let id: Int }

struct KeySurface: View {
    var color: Color = .clear
    var illuminated = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(color.opacity(illuminated ? 0.22 : 0.05))
                .shadow(color: color.opacity(illuminated ? 0.38 : 0), radius: 9)
            if let artwork = UIImage(named: "ControllerKey") {
                Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit().scaleEffect(1.15).opacity(illuminated ? 0.9 : 1)
            } else {
                RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.white, Color(white: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 3)
            }
        }.overlay(RoundedRectangle(cornerRadius: 15).stroke(color.opacity(illuminated ? 0.6 : 0), lineWidth: 1.5))
    }
}

struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.955 : 1).offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DialControl: View {
    let silver: Bool
    let caption: String
    let color: Color
    let turn: (Int) -> Void
    let press: () -> Void
    @State private var steps = 0
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let artwork = UIImage(named: silver ? "ControllerDialSilver" : "ControllerDial") {
                    Image(uiImage: artwork).renderingMode(.original).resizable().scaledToFit()
                } else {
                    Circle().fill(silver ? Color.gray.opacity(0.25) : GenesisPalette.ink).padding(3)
                    Capsule().fill(silver ? GenesisPalette.ink.opacity(0.6) : .white.opacity(0.8)).frame(width: 3, height: 12).offset(y: -17)
                }
            }.rotationEffect(.degrees(rotation))
            Text(caption).font(.system(size: 7, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(.secondary)
        }.contentShape(Rectangle()).onTapGesture(perform: press)
            .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                let next = Int((value.translation.width - value.translation.height) / 20)
                if next != steps { let delta = next - steps; turn(delta); rotation += Double(delta) * 22; steps = next; UISelectionFeedbackGenerator().selectionChanged() }
            }.onEnded { _ in steps = 0 })
            .accessibilityElement(children: .ignore).accessibilityLabel(caption == "CHATS" ? "Chat dial" : "Artifact dial")
            .accessibilityAdjustableAction { direction in turn(direction == .increment ? 1 : -1) }
            .accessibilityAction { press() }
    }
}

struct PixelLight: View {
    let color: Color
    let working: Bool
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !working || reduceMotion)) { context in
            let phase = Int(context.date.timeIntervalSince1970 * 4) % 12
            VStack(spacing: 2) {
                ForEach(0..<5) { row in HStack(spacing: 2) {
                    ForEach(0..<5) { column in
                        let i = row * 5 + column
                        let lit = working ? ((i + phase) % 7 < 2) : [11, 12, 13].contains(i)
                        Circle().fill(color.opacity(lit ? 0.9 : 0.12)).frame(width: 4, height: 4)
                    }
                }
                }
            }
        }.accessibilityHidden(true)
    }
}
