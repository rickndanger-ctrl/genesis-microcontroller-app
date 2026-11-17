import SwiftUI
import UIKit

struct ControllerScreen: View {
    @ObservedObject var store: ControllerStore
    @State private var showSettings = false
    @State private var showArtifacts = false
    @State private var showActions = false
    @State private var showNavigation = false
    @State private var quickMappingIndex: Int?
    @State private var mappingIndex: Int?
    @State private var dialSlot: Int?
    /// A key pressed while the Mac was still answering the one before it.
    @State private var deferredTap: DeferredTap?
    @State private var heldTalk = false
    @GestureState private var talkGestureActive = false
    @State private var talkGestureID: UUID?
    @State private var talkStopTask: Task<Void, Never>?
    @State private var blockedTalkReason: String?
    @State private var artifactID: String?
    @State private var dialArtifactPreview: ArtifactRecord?
    @State private var resolvingSend = false
    @State private var fullScreenController: Bool
    @State private var showDraftReview = false
    @State private var showGlassesControls = false
    @State private var chatDialRotation: Double
    @State private var artifactDialRotation = 0.0
    @State private var chatDialActive = false
    @State private var artifactDialActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let fullScreenKey = "controllerFullScreen"
    /// Off hides every glasses control. See `GlassesFeature`.
    @AppStorage private var glassesFeature: Bool

    /// Opens the sample controller. Present only on a real, unpaired install.
    private let startDemo: (() -> Void)?
    /// Leaves the sample controller. Present only when it was opened in the app.
    private let endDemo: (() -> Void)?

    init(store: ControllerStore, startDemo: (() -> Void)? = nil, endDemo: (() -> Void)? = nil) {
        self.store = store
        self.startDemo = startDemo
        self.endDemo = endDemo
        _glassesFeature = AppStorage(wrappedValue: false, GlassesFeature.storageKey(demo: store.isDemo))
        // The demo always opens on the dashboard so previews and UI tests
        // start from one known layout.
        _fullScreenController = State(initialValue: !store.isDemo && UserDefaults.standard.bool(forKey: Self.fullScreenKey))
        _chatDialRotation = State(initialValue: Double(store.selectedSlotIndex ?? 0) * 60)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var browsedSlot: Int { dialSlot ?? store.selectedSlotIndex ?? 0 }
    private var slotColor: Color { GenesisPalette.glow(store.selectedSlotIndex ?? browsedSlot) }
    private var artifactIndex: Int { store.artifacts.firstIndex { $0.id == artifactID } ?? 0 }
    private var artifactSelectionLabel: String {
        guard store.artifacts.indices.contains(artifactIndex) else { return "No artifacts" }
        return store.artifacts[artifactIndex].title
    }
    private var providerName: String { store.selectedProvider.rawValue == "codex" ? "Codex" : store.selectedProvider.rawValue.capitalized }
    private var codexDraftOnly: Bool { store.selectedProvider == .codex && store.providerInfo?.supports("sendPrompt") != true }
    private var codexQueuesPrompt: Bool { store.selectedProvider == .codex && store.providerInfo?.supports("sendPrompt") == true }
    private var slotPrefix: String { store.selectedProvider == .claude ? "C" : store.selectedProvider == .muse ? "M" : "A" }
    private var canChangeLayout: Bool {
        !heldTalk && !talkGestureActive && !store.isRecording && !store.isFinalizing && !chatDialActive && !artifactDialActive
    }
    /// A draft is growing under dictation right now.
    private var dictatingDraft: Bool { (store.isRecording || store.isFinalizing) && !store.draft.isEmpty }
    private var selectedComputerName: String { store.hosts.first { $0.id == store.selectedHostID }?.name ?? "Pair a Mac" }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if fullScreenController { focusedLayout(in: geometry.size) }
                else { controllerLayout(in: geometry.size) }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(GenesisBackdrop(color: slotColor))
            .foregroundStyle(GenesisPalette.text)
        }
        .statusBarHidden(fullScreenController)
        .persistentSystemOverlays(fullScreenController ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) { SettingsScreen(store: store, endDemo: endDemo) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let endDemo {
                // Always in reach, in either layout, so the demo is never a dead end.
                HStack(spacing: 10) {
                    Label("Demo · sample chats, no Mac contacted", systemImage: "play.circle").lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button("Exit demo") { ControllerSound.shared.keyClick(); endDemo() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("controller.exitDemo")
                }
                .font(.system(size: isPad ? 14 : 12, weight: .semibold))
                .foregroundStyle(GenesisPalette.text)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showArtifacts) { ArtifactShelf(store: store, initialIndex: artifactIndex) }
        .sheet(item: $dialArtifactPreview) { ArtifactPreview(store: store, artifact: $0) }
        .sheet(isPresented: $showActions, onDismiss: routeRequestedPanel) { ActionBrowser(store:store) }
        .sheet(isPresented: $showNavigation) { MenuNavigationScreen(store:store) }
        .sheet(isPresented: $showDraftReview) { draftReview }
        .sheet(isPresented: $showGlassesControls) { glassesControls }
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
        .onChange(of: browsedSlot) { _, slot in pointChatDial(at: slot, animated: true) }
        .onChange(of: store.isBusy) { _, busy in if !busy { runDeferredTap() } }
        .onChange(of: chatDialActive) { _, active in if !active { pointChatDial(at: browsedSlot, animated: true) } }
        .onChange(of: store.requestedPanel) { _, panel in
            if !showActions { routeRequestedPanel() }
        }
    }

    /// Turns the chat dial the short way round to the given slot's light.
    /// While a finger is on the dial it leads, and this waits for it to lift.
    private func pointChatDial(at slot: Int, animated: Bool) {
        guard !chatDialActive else { return }
        let offset = (Double(slot) * 60 - chatDialRotation).truncatingRemainder(dividingBy: 360)
        let shortest = offset > 180 ? offset - 360 : offset < -180 ? offset + 360 : offset
        guard abs(shortest) > 0.01 else { return }
        withAnimation(animated && !reduceMotion ? .spring(response: 0.32, dampingFraction: 0.72) : nil) { chatDialRotation += shortest }
    }

    private func setFullScreen(_ enabled: Bool) {
        guard canChangeLayout else { return }
        ControllerSound.shared.keyClick()
        fullScreenController = enabled
        if !store.isDemo { UserDefaults.standard.set(enabled, forKey: Self.fullScreenKey) }
    }

    @ViewBuilder private func focusedLayout(in size: CGSize) -> some View {
        let wide = isPad && size.width >= 930 && size.width > size.height && !dynamicTypeSize.isAccessibilitySize
        if wide {
            let rail: CGFloat = 320
            HStack(alignment: .center, spacing: 20) {
                deck(width: max(300, size.width - rail - 52), height: max(300, size.height - 32))
                VStack(spacing: 14) {
                    focusedRoute
                    focusedStatus
                    focusedDraft
                    focusedTools
                }.frame(width: rail)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: size.height)
        } else {
            // The deck takes every point the status and draft strips leave,
            // growing taller than square on a phone. Real key targets survive
            // a short window (keyboard, large type); the scroll view is the fallback.
            let chrome: CGFloat = isPad ? 330 : 300
            VStack(spacing: 10) {
                focusedRoute
                focusedStatus
                deck(width: size.width - 16, height: max(300, size.height - chrome))
                focusedDraft
                focusedTools
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: size.height)
        }
    }

    private var focusedRoute: some View {
        HStack(spacing: 6) {
            Button { setFullScreen(false) } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 44, height: 44)
                    .genesisPanel(radius: 14)
            }
            .accessibilityLabel("Exit full screen")
            .accessibilityIdentifier("controller.exitFullscreen")
            .disabled(!canChangeLayout)
            Menu {
                ForEach(store.hosts) { host in
                    Button { ControllerSound.shared.keyClick(); store.selectHost(host.id) } label: {
                        Label(host.name, systemImage: host.id == store.selectedHostID ? "checkmark" : "desktopcomputer")
                    }
                }
                Button("Pair a Mac", systemImage: "plus") { ControllerSound.shared.keyClick(); showSettings = true }
            } label: {
                routeLabel(selectedComputerName, icon: "macmini")
            }
            .accessibilityLabel("Choose computer").accessibilityValue(selectedComputerName)
            .accessibilityIdentifier("controller.chooseComputer")
            Menu {
                ForEach([ProviderID.codex, .claude, .muse], id: \.rawValue) { provider in
                    Button {
                        ControllerSound.shared.keyClick(); store.selectProvider(provider)
                    } label: {
                        Label(provider == .codex ? "Codex" : provider.rawValue.capitalized,
                              systemImage: provider == store.selectedProvider ? "checkmark" : "bubble.left")
                    }
                }
            } label: { routeLabel(providerName, icon: providerIcon(store.selectedProvider)) }
            .accessibilityLabel("Choose provider").accessibilityValue(providerName)
            .accessibilityIdentifier("controller.chooseProvider")
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(GenesisPalette.text)
    }

    private func providerIcon(_ provider: ProviderID) -> String {
        provider == .codex ? "terminal" : provider == .claude ? "sun.max" : "sparkle"
    }

    private func routeLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(slotColor)
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(GenesisPalette.dim)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 6)
        .genesisPanel(radius: 14)
    }

    /// One strip for the selected chat and the link to its Mac.
    private var focusedStatus: some View {
        HStack(spacing: 10) {
            Circle().fill(slotColor).frame(width: 9, height: 9).shadow(color: slotColor, radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedChat?.title ?? "Choose a chat")
                    .font(.system(size: isPad ? 18 : 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .accessibilityIdentifier("controller.currentChat")
                HStack(spacing: 5) {
                    Circle().fill(store.providerInfo?.readiness == "ready" ? Color.green : Color.orange).frame(width: 5, height: 5)
                    Text(store.connectionMessage).font(.system(size: isPad ? 12 : 11, weight: .medium)).lineLimit(1)
                }.foregroundStyle(GenesisPalette.dim)
            }
            Spacer(minLength: 0)
            if store.isBusy { ProgressView().controlSize(.mini) }
            Button { ControllerSound.shared.keyClick(); Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
            }
            .foregroundStyle(GenesisPalette.dim)
            .accessibilityLabel("Refresh connection and chats")
        }
        .padding(.leading, 14).padding(.trailing, 2).padding(.vertical, 4)
        .genesisPanel(radius: 16)
    }

    private var focusedDraft: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button { ControllerSound.shared.keyClick(); showDraftReview = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.isRecording ? "Listening…" : store.isFinalizing ? "Finishing…" : "Review draft")
                            .font(.caption.weight(.semibold)).foregroundStyle(slotColor)
                        Text(store.draft.isEmpty ? "Hold Talk, then release to review." : store.draft)
                            .font(.system(size: isPad ? 16 : 14)).lineLimit(2)
                            .foregroundStyle(store.draft.isEmpty ? GenesisPalette.dim : GenesisPalette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Two lines cut a long dictation off at its start, hiding
                            // the words being spoken. While listening, show its end.
                            .opacity(dictatingDraft ? 0 : 1)
                            .overlay { if dictatingDraft { LiveDraft(text: store.draft, size: isPad ? 16 : 14) } }
                    }.frame(minHeight: 54, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!canChangeLayout)
                .accessibilityLabel("Review draft").accessibilityIdentifier("controller.reviewDraft")
                sendDraftButton
            }
            if store.hasUnresolvedSend {
                Text("Delivery unconfirmed · Open Review draft to check")
                    .font(.caption).foregroundStyle(.orange)
            } else if let receipt = store.lastReceipt {
                Text(receipt.message).font(.caption).foregroundStyle(GenesisPalette.dim).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .genesisPanel(radius: 20)
    }

    private var sendDraftButton: some View {
        Button { ControllerSound.shared.keyClick(); Task { await store.sendDraft() } } label: {
            Label("Send", systemImage: "arrow.up")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(minWidth: 56, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(slotColor)
        .shadow(color: slotColor.opacity(store.canSend ? 0.45 : 0), radius: 8, y: 3)
        .disabled(!store.canSend)
        .accessibilityIdentifier("controller.sendDraft")
        .accessibilityHint("Send the reviewed draft to the selected Mac chat once.")
    }

    private var focusedTools: some View {
        HStack(spacing: 8) {
            Button { ControllerSound.shared.keyClick(); showActions = true } label: {
                Label("Actions", systemImage: "square.grid.2x2").frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            if glassesFeature {
                FocusedGlassesAccess(follow: store.glasses) {
                    ControllerSound.shared.keyClick(); showGlassesControls = true
                }
            } else {
                Spacer(minLength: 0)
            }
            Button { ControllerSound.shared.keyClick(); showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).genesisPanel(radius: 14)
            }.accessibilityLabel("Settings and Mac pairing")
        }.font(.system(size: 13, weight: .semibold)).foregroundStyle(GenesisPalette.text).disabled(!canChangeLayout)
    }

    private var draftReview: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    composer
                    sendDraftButton
                    if let error = store.lastError {
                        Text(error).font(.callout).foregroundStyle(.red)
                            .accessibilityIdentifier("controller.draftError")
                    }
                }.padding()
            }
            .navigationTitle("Review draft").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { ControllerSound.shared.keyClick(); showDraftReview = false }
            } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var glassesControls: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GlassesFollowPanel(store: store, follow: store.glasses)
                    if let error = store.lastError {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }.padding()
            }
                .navigationTitle("Glasses").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { ControllerSound.shared.keyClick(); showGlassesControls = false }
                } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
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
                deck(width: deckSize, height: deckSize)
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
                deck(width: deckSize, height: deckSize)
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
            .foregroundStyle(GenesisPalette.dim)
            .buttonStyle(.plain)
        }
        composer
        if glassesFeature { GlassesFollowPanel(store: store, follow: store.glasses) }
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
        dialSlot = nil; deferredTap = nil; artifactID = nil; heldTalk = false; talkGestureID = nil; blockedTalkReason = nil
        showArtifacts = false; mappingIndex = nil; resolvingSend = false
        showActions = false; showNavigation = false; quickMappingIndex = nil; store.requestedPanel = nil
        showDraftReview = false; showGlassesControls = false
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
                Text("CONTROL DECK").font(.system(size: isPad ? 14 : 12, weight: .black, design: .rounded)).tracking(5)
                Text("Agent Micro Controller").font(.system(size: isPad ? 28 : 22, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 4)
            Button { setFullScreen(true) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: isPad ? 21 : 18)).frame(width: isPad ? 52 : 44, height: isPad ? 52 : 44)
                    .genesisPanel(radius: 26, raised: true)
            }
            .accessibilityLabel("Full screen controller")
            .accessibilityIdentifier("controller.fullscreen")
            .disabled(!canChangeLayout)
            Button { ControllerSound.shared.keyClick(); showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: isPad ? 21 : 18)).frame(width: isPad ? 52 : 44, height: isPad ? 52 : 44)
                    .genesisPanel(radius: 26)
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
                            .genesisPanel(radius: 13, raised: true)
                    }
                    if let startDemo {
                        // Someone without the Mac companion yet can still see what the controller does.
                        Button { ControllerSound.shared.keyClick(); startDemo() } label: {
                            Label("Try the demo", systemImage: "play.circle")
                                .font(.system(size: isPad ? 14 : 12, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: isPad ? 48 : 42)
                                .genesisPanel(radius: 13)
                        }
                        .accessibilityIdentifier("controller.tryDemo")
                        .accessibilityHint("Opens a sample controller. No Mac is contacted.")
                    }
                }
                ForEach(store.hosts) { host in
                    let selected = store.selectedHostID == host.id
                    Button { ControllerSound.shared.keyClick(); store.selectHost(host.id) } label: {
                        Label(host.name, systemImage: host.name.lowercased().contains("neo") ? "laptopcomputer" : "macmini")
                            .font(.system(size: isPad ? 14 : 12, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: isPad ? 48 : 42)
                            .foregroundStyle(selected ? GenesisPalette.text : GenesisPalette.dim)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(GenesisPalette.panelRaised)
                                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(slotColor.opacity(0.55), lineWidth: 1))
                                        .shadow(color: slotColor.opacity(0.30), radius: 6, y: 2)
                                }
                            }
                    }.accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(4).genesisPanel(radius: 17)
            HStack(spacing: 6) {
                ForEach([ProviderID.codex, .claude, .muse], id: \.rawValue) { provider in
                    let selected = store.selectedProvider == provider
                    Button { ControllerSound.shared.keyClick(); store.selectProvider(provider) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: providerIcon(provider))
                            Text(provider == .codex ? "Codex" : provider.rawValue.capitalized)
                        }.font(.system(size: isPad ? 15 : 13, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: isPad ? 48 : 42)
                            .foregroundStyle(selected ? Color.white : GenesisPalette.ink)
                            .background {
                                if selected { Capsule().fill(GenesisPalette.ink).shadow(color: slotColor.opacity(0.40), radius: 8, y: 3) }
                                else { Capsule().fill(GenesisPalette.panel).overlay(Capsule().strokeBorder(GenesisPalette.hairline, lineWidth: 1)) }
                            }
                    }.accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var connection: some View {
        HStack(spacing: 8) {
            Circle().fill(store.providerInfo?.readiness == "ready" ? Color.green : Color.orange).frame(width: isPad ? 8 : 6, height: isPad ? 8 : 6)
                .shadow(color: store.providerInfo?.readiness == "ready" ? .green : .orange, radius: 4)
            Text(store.connectionMessage).font(.system(size: isPad ? 14 : 11, weight: .medium)).lineLimit(1)
            Spacer()
            if store.isBusy { ProgressView().controlSize(.mini) }
            Button { ControllerSound.shared.keyClick(); Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: isPad ? 44 : 32, height: isPad ? 44 : 30) }
                .accessibilityLabel("Refresh connection and chats")
        }.foregroundStyle(GenesisPalette.dim).padding(.horizontal, 7)
    }

    private func slotTitle(_ index: Int) -> String {
        guard let mapping = store.profile.slots.first(where: { $0.index == index }), mapping.kind != "empty", !mapping.title.isEmpty else {
            return "Assign"
        }
        return mapping.title
    }

    /// Runs a key that was held back while the Mac finished the one before
    /// it. It is dropped instead if that command failed or took too long.
    private func runDeferredTap() {
        guard let tap = deferredTap else { return }
        deferredTap = nil
        guard tap.shouldRun(now: Date(), previousSucceeded: store.lastError == nil) else { return }
        switch tap.target {
        case .slot(let index): activateSlot(index, replayed: true)
        case .action(let id): runQuickAction(id, replayed: true)
        }
    }

    private func activateSlot(_ index: Int, replayed: Bool = false) {
        let selectedMapping = store.profile.slots.first { $0.index == index }
        guard !store.isBusy else {
            // Hold the press for the command in flight rather than lose it.
            // A key mapped to Send or dictation never waits.
            if selectedMapping?.kind == "action", !DeferredTap.mayWait(selectedMapping?.targetID ?? "") { return }
            ControllerSound.shared.keyClick()
            dialSlot = index
            deferredTap = DeferredTap(target: .slot(index), pressed: Date())
            return
        }
        // A second press on the chat that has just opened has nothing left to do.
        if replayed, selectedMapping?.kind == "chat", store.selectedSlotIndex == index { dialSlot = nil; return }
        dialSlot = index
        let dictationAction = selectedMapping?.kind == "action" && selectedMapping?.targetID == "dictate"
        let stoppingDictation = dictationAction && store.isRecording
        if dictationAction { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        else if !replayed { ControllerSound.shared.keyClick() }
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

    /// The largest chassis that fits: full width and up to 30% taller than
    /// square when there is height to spare, otherwise square.
    private func deckFit(width: CGFloat, height: CGFloat) -> CGSize {
        let width = max(0, width), height = max(0, height)
        if height >= width { return CGSize(width: width, height: min(height, width * 1.30)) }
        return CGSize(width: height, height: height)
    }

    private func deck(width: CGFloat, height: CGFloat) -> some View {
        let fit = deckFit(width: width, height: height)
        let side = min(fit.width, fit.height)
        let scale = isPad ? max(1, side / 430) : 1
        let gap: CGFloat = 8 * scale
        // Keys sit on the rendered plate, inside the rim. The rim's size is
        // fixed by the render's scale, which follows the deck's width.
        let pad = fit.width * 0.030
        let left = fit.width * DeckArt.plateSide + pad
        let top = fit.width * DeckArt.plateTop + pad
        let bottom = fit.width * DeckArt.plateBottom + pad
        let wall = fit.width * DeckArt.frontWall
        let keyW = max(0, (fit.width - left * 2 - gap * 3) / 4)
        let keyH = max(0, (fit.height - top - bottom - gap * 3) / 4)
        // The knob in use glows as hard as its key.
        let chatDialLevel = store.selectedSlotIndex == nil ? 0.30 : browsedSlot == store.selectedSlotIndex ? 1.0 : 0.62
        let browsingUnopened = dialSlot != nil && dialSlot != store.selectedSlotIndex
        return ZStack {
            DeckChassis(glow: slotColor, scale: scale)
            VStack(spacing: 0) {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        DialControl(silver: true, caption: "CHATS", color: GenesisPalette.glow(browsedSlot), level: chatDialLevel, ringSelection: browsedSlot,
                                    degreesPerStep: 60, restingRotation: $chatDialRotation, scale: scale,
                                    interactionChanged: { chatDialActive = $0 },
                                    selectionDescription: "\(slotPrefix)\(browsedSlot + 1), \(slotTitle(browsedSlot))",
                                    visibleSelection: browsingUnopened ? "PRESS TO OPEN" : nil, turn: { delta in
                            dialSlot = ((browsedSlot + delta) % 6 + 6) % 6
                        }, press: { activateSlot(browsedSlot) }).frame(width: keyW, height: keyH)
                        slot(0, width: keyW, height: keyH, scale: scale)
                        slot(1, width: keyW, height: keyH, scale: scale)
                        DialControl(silver: false, caption: "ARTIFACTS", color: slotColor, restingRotation: $artifactDialRotation, scale: scale,
                                    interactionChanged: { artifactDialActive = $0 },
                                    selectionDescription: artifactSelectionLabel,
                                    visibleSelection: artifactID.flatMap { id in store.artifacts.first { $0.id == id }?.title },
                                    turn: turnArtifactDial, press: {
                            ControllerSound.shared.keyClick()
                            if let artifactID, let artifact = store.artifacts.first(where: { $0.id == artifactID }) {
                                dialArtifactPreview = artifact
                            } else {
                                showArtifacts = true
                            }
                        }).frame(width: keyW, height: keyH)
                    }
                    HStack(spacing: gap) { ForEach(2..<6) { slot($0, width: keyW, height: keyH, scale: scale) } }
                    HStack(spacing: gap) {
                        ForEach(0..<4, id: \.self) { index in quickActionKey(index, width: keyW, height: keyH, scale: scale) }
                    }
                    HStack(spacing: gap) {
                        Button { ControllerSound.shared.keyClick(); dialSlot = nil; deferredTap = nil; store.returnHome() } label: {
                            PixelLight(color: slotColor, working: store.isBusy, reduceMotion: reduceMotion, scale: scale)
                        }
                        .buttonStyle(HomePuckStyle(color: slotColor, caption: "HOME", scale: scale))
                        .frame(width: keyW, height: keyH)
                        .accessibilityLabel("Return to chat selection")
                        talkKey(width: keyW * 2 + gap, height: keyH, scale: scale)
                        actionKey("Map", icon: "slider.horizontal.3", width: keyW, height: keyH, scale: scale, enabled: true) { mappingIndex = browsedSlot }
                    }
                }
            }
            .padding(.top, top).padding(.bottom, bottom)
            .frame(width: fit.width, height: fit.height, alignment: .top)
            // Printed on the front wall of the body.
            Text("YOUR AGENTS. ONE PLACE.").font(.system(size: 6.5 * scale, weight: .semibold, design: .monospaced)).tracking(1.8 * scale)
                .foregroundStyle(GenesisPalette.ink.opacity(0.38))
                .frame(width: fit.width, height: wall)
                .frame(height: fit.height, alignment: .bottom)
                .offset(y: -wall * 0.18)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }.frame(width: fit.width, height: fit.height)
    }

    private func slot(_ index: Int, width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        let title = slotTitle(index)
        let selected = store.selectedSlotIndex == index
        let browsed = browsedSlot == index
        let color = GenesisPalette.glow(index)
        let assigned = store.profile.slots.contains { $0.index == index && $0.kind != "empty" }
        return HoldTapKeycap(led: color, level: selected ? 1 : browsed ? 0.60 : assigned ? 0.30 : 0.07, breathing: selected, scale: scale, unit: width,
                             tap: { activateSlot(index) },
                             hold: { ControllerSound.shared.keyClick(); mappingIndex = index }) {
            VStack(spacing: 4 * scale) {
                HStack(spacing: 4 * scale) {
                    Circle().fill(GenesisPalette.color(index).opacity(assigned ? 1 : 0.45))
                        .frame(width: 7 * scale, height: 7 * scale)
                        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 0.7 * scale))
                    Text("\(slotPrefix)\(index + 1)")
                        .font(.system(size: 11 * scale, weight: .heavy, design: .monospaced))
                }
                Text(title)
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(width: max(0, width * 0.78 - 4 * scale), height: 22 * scale, alignment: .top)
            }
        }
        .frame(width: width, height: height)
            .overlay {
                if browsed && !selected {
                    // The dial's unopened selection: a bright dashed ring just outside the cap.
                    RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                        .strokeBorder(GenesisPalette.ink.opacity(0.75), style: StrokeStyle(lineWidth: 1.4 * scale, dash: [3.5 * scale, 2.5 * scale]))
                        .padding(-3 * scale)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(slotPrefix)\(index + 1), \(title)")
            .accessibilityValue(selected && browsed ? "Current chat, dial selection" : selected ? "Current chat" : browsed ? "Dial selection" : "")
            .accessibilityAction { activateSlot(index) }
            .accessibilityAction(named: "Change assignment") { ControllerSound.shared.keyClick(); mappingIndex = index }
    }

    private func actionKey(_ title: String, icon: String, width: CGFloat, height: CGFloat, scale: CGFloat, active: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { ControllerSound.shared.keyClick(); action() } label: {
            VStack(spacing: 6 * scale) {
                Image(systemName: icon).font(.system(size: 18 * scale, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 8.5 * scale, weight: .bold, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail).frame(width: max(0, width * 0.78 - 4 * scale))
            }.opacity(enabled ? 1 : 0.42)
        }
        .buttonStyle(KeycapButtonStyle(led: slotColor, level: active ? 1 : enabled ? 0.10 : 0.03, scale: scale, unit: width))
        .frame(width: width, height: height)
        .disabled(!enabled).accessibilityLabel(title)
    }
    private func quickActionKey(_ index: Int, width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        let id = store.profile.quickActionIDs[index]
        let action = store.action(id)
        let titles = ["sendPrompt":"Send", "stop":"Stop", "nativeVoice":"Voice", "artifacts":"Artifacts", "modelAndEffort":"Model"]
        let title = titles[id] ?? action?.title ?? "Unavailable"
        // A key that is only waiting on the command in flight stays lit, so
        // the row does not flicker dim with every press.
        let enabled = store.canRunAction(id) || store.canDeferAction(id)
        let armed = id == "sendPrompt" && store.sendReady && enabled
        let waiting = deferredTap?.target == .action(id)
        // Utility keys take the selected chat's color, so the whole deck
        // shifts hue together when the chat changes.
        return HoldTapKeycap(led: slotColor, level: armed ? 0.85 : waiting ? 0.60 : enabled ? 0.10 : 0.03, scale: scale, unit: width,
                             tap: { runQuickAction(id) },
                             hold: { ControllerSound.shared.keyClick(); quickMappingIndex = index }) {
            VStack(spacing: 6 * scale) {
                Image(systemName:action?.icon ?? "questionmark").font(.system(size: 18 * scale, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 8.5 * scale, weight: .bold, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(width: max(0, width * 0.78 - 4 * scale))
            }.opacity(enabled ? 1 : 0.42)
        }
        .frame(width: width, height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton).accessibilityLabel(title)
            .accessibilityHint(enabled ? "Tap to run. Hold to change this action." : store.actionUnavailableReason(id) ?? "This action is not available.")
            .accessibilityAction { runQuickAction(id) }
            .accessibilityAction(named:"Change action") { ControllerSound.shared.keyClick(); quickMappingIndex = index }
    }

    private func runQuickAction(_ id: String, replayed: Bool = false) {
        if store.canDeferAction(id) {
            ControllerSound.shared.keyClick()
            deferredTap = DeferredTap(target: .action(id), pressed: Date())
            return
        }
        let dictationAction = id == "dictate"
        let stoppingDictation = dictationAction && store.isRecording
        if dictationAction { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        else if !replayed { ControllerSound.shared.keyClick() }
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
        // The cap stays down, fully lit and breathing, for as long as the
        // microphone is live. Capture start keeps its own soft haptic.
        Keycap(led: slotColor, level: store.isRecording ? 1 : store.canDictate ? 0.13 : 0.03, breathing: store.isRecording,
               pressed: talkGestureActive || heldTalk || store.isRecording, scale: scale, haptic: false, unit: (width - 8 * scale) / 2) {
            VStack(spacing: 5 * scale) {
                Image(systemName: store.dictationControl.icon).font(.system(size: 23 * scale, weight: .semibold))
                Text(store.dictationControl.label)
                    .font(.system(size: 8.5 * scale, weight: .bold, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail).frame(width: max(0, width - 16 * scale))
            }.opacity(store.canDictate ? 1 : 0.38)
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
                Circle().fill(slotColor).frame(width: 7, height: 7).shadow(color: slotColor, radius: 5)
                Text(store.selectedChat?.title ?? "Choose a chat to begin").font(.system(size: isPad ? 17 : 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(providerName).font(isPad ? .caption : .caption2).foregroundStyle(GenesisPalette.dim)
            }
            TextField(codexDraftOnly ? "Local draft — Send is not connected yet" : "Hold the microphone, or type a draft…", text: $store.draft, axis: .vertical)
                .font(.system(size: isPad ? 17 : 14)).lineLimit(isPad ? 3...8 : 2...5).disabled(store.selectedChat == nil || store.isRecording || store.isFinalizing)
                // The field shows its first lines and cannot scroll while it
                // is disabled for dictation, so new words past the last line
                // never appeared. The live view over it follows the newest.
                // Faded out whole, not just its text, so spelling marks from
                // typing cannot show through under different words. It is not
                // taken to zero: a fully transparent field leaves the
                // accessibility tree, and VoiceOver must still read the draft.
                .opacity(dictatingDraft ? 0.02 : 1)
                .overlay { if dictatingDraft { LiveDraft(text: store.draft, size: isPad ? 17 : 14) } }
                .accessibilityLabel("Draft for selected chat")
                .accessibilityIdentifier("controller.draft")
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
        }.padding(isPad ? 20 : 16).genesisPanel(radius: 20)
            .confirmationDialog("Check this exact chat on your Mac first", isPresented: $resolvingSend, titleVisibility: .visible) {
                Button("I checked — the prompt arrived") { ControllerSound.shared.keyClick(); store.acknowledgeUncertainSend(wasSent: true) }
                Button("I checked — it did not arrive") { ControllerSound.shared.keyClick(); store.acknowledgeUncertainSend(wasSent: false) }
                Button("Keep waiting", role: .cancel) { ControllerSound.shared.keyClick() }
            } message: { Text("This only resolves the saved receipt. Nothing is sent by choosing an answer.") }
    }
}

/// The draft while it is being dictated, pinned to its newest line so the
/// words just spoken are always in view. Display only: the field beneath it
/// still owns the text and its accessibility.
private struct LiveDraft: View {
    let text: String
    let size: CGFloat
    var body: some View {
        ScrollView(.vertical) {
            Text(text).font(.system(size: size)).foregroundStyle(GenesisPalette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Follow the end as it grows, but sit at the top while the text is
        // still shorter than the box, where the field beneath draws it.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FocusedGlassesAccess: View {
    @ObservedObject var follow: GlassesFollowController
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "eyeglasses")
                Text(follow.acknowledged ? "Synced" : follow.connecting ? "Connecting" : follow.enabled ? "Waiting" : "Glasses").lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(follow.acknowledged ? .green : .secondary)
        .accessibilityIdentifier("controller.glasses")
        .accessibilityLabel("Glasses controls")
        .accessibilityValue(follow.message)
    }
}

private struct MappingSelection: Identifiable { let id: Int }

struct DialControl: View {
    let silver: Bool
    let caption: String
    let color: Color
    var level: Double = 0.4
    var ringSelection: Int?
    var degreesPerStep = DialTracking.degreesPerStep
    @Binding var restingRotation: Double
    var scale: CGFloat = 1
    var interactionChanged: (Bool) -> Void = { _ in }
    var selectionDescription: String = ""
    var visibleSelection: String?
    let turn: (Int) -> Void
    let press: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var tracking: DialTracking?
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let size = geometry.size
                DialKnob(finish: silver ? .snow : .graphite, color: color, level: level, ringSelection: ringSelection,
                         rotation: restingRotation + (tracking?.degrees ?? 0), active: isDragging, pressed: pressed, scale: scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(drag(in: size).exclusively(before: TapGesture()).onEnded { gesture in
                    switch gesture {
                    case .first(let value):
                        updateDrag(value, in: size)
                        // A press with a slightly unsteady finger is still a press.
                        let nudge = tracking.map { $0.steps == 0 && $0.travel < 11 * scale } ?? false
                        finishDrag()
                        if nudge { pressDial() }
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
                .foregroundStyle(GenesisPalette.ink.opacity(visibleSelection == nil ? 0.55 : 0.85))
        }
        .onChange(of: isDragging) { _, active in
            interactionChanged(active)
            if !active { finishDrag() }
        }
        .onDisappear {
            finishDrag()
            interactionChanged(false)
        }
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

    private func drag(in size: CGSize) -> some Gesture<DragGesture.Value> {
        DragGesture(minimumDistance: 6 * scale)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { updateDrag($0, in: size) }
    }

    private func updateDrag(_ value: DragGesture.Value, in size: CGSize) {
        // Turns are measured around the top face the finger sees, which the
        // tilted render draws above the middle of the frame and slightly flat.
        let face = DialKnob.face(in: size)
        func onFace(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - face.center.x, y: (point.y - face.center.y) / DeckArt.flat)
        }
        var current = tracking ?? DialTracking(start: onFace(value.startLocation), center: .zero,
                                               radius: face.radius, degreesPerStep: degreesPerStep,
                                               swipeDistance: 28 * scale)
        let change = current.move(to: onFace(value.location))
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
            restingRotation += Double(tracking.steps) * degreesPerStep
            self.tracking = nil
        }
    }

    private func pressDial() {
        // The destination owns feedback so mapped microphone actions start
        // with haptics only, including activation from the chat dial.
        pressed = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            pressed = false
        }
        press()
    }

    private func adjust(by steps: Int) {
        ControllerSound.shared.dialTick()
        turn(steps)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            restingRotation += Double(steps) * degreesPerStep
        }
    }
}
