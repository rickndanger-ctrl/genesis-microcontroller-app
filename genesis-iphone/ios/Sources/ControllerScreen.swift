import SwiftUI
import UIKit

struct ControllerScreen: View {
    @ObservedObject var store: ControllerStore
    @State private var showSettings = false
    @State private var showGuide = false
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
    /// Dashboard, full screen with a side panel, or (iPad) the deck alone.
    @State private var controllerSize: ControllerSize
    private var fullScreenController: Bool { controllerSize != .dashboard }
    /// The window's size, for controls outside the layout functions.
    @State private var screenSize: CGSize = .zero
    @AppStorage("threadPaneHidden") private var threadHidden = false
    @State private var showDraftReview = false
    /// The thread as a sheet, wherever it is not already a pane beside or inside the deck.
    @State private var showThread = false
    @State private var threadDetent = PresentationDetent.large
    @FocusState private var draftFocused: Bool
    @State private var showGlassesControls = false
    @State private var chatDialRotation: Double
    @State private var artifactDialRotation = 0.0
    @State private var chatDialActive = false
    @State private var artifactDialActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let fullScreenKey = "controllerFullScreen"
    static let sizeKey = "controllerSize"
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
        _controllerSize = State(initialValue: store.isDemo ? .dashboard : Self.savedSize())
        _chatDialRotation = State(initialValue: Double(store.selectedSlotIndex ?? 0) * 60)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var browsedSlot: Int { dialSlot ?? store.selectedSlotIndex ?? 0 }
    @AppStorage(DeckTheme.storageKey) private var themeID = DeckTheme.aurora.rawValue
    private var theme: DeckTheme { DeckTheme(rawValue: themeID) ?? .aurora }
    /// What the open chat (or the one the dial rests on) is doing.
    private var deckActivity: ChatActivity? { store.selectedSlotIndex == nil ? store.activity(slot: browsedSlot) : store.selectedActivity }
    /// The deck's accent: the chat's light when it has one, otherwise the theme's color.
    private var slotColor: Color { theme.accent(deckActivity) }
    /// The light inside the utility keys. Caps stay out of the theme: color on a cap means status.
    private var capColor: Color { GenesisPalette.accent(deckActivity) }
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
                Group {
                    if controllerSize == .deckOnly && deckOnlyFits(geometry.size) { deckOnlyLayout(in: geometry.size) }
                    else if fullScreenController { focusedLayout(in: geometry.size) }
                    else { controllerLayout(in: geometry.size) }
                }
            }
            .onChange(of: geometry.size, initial: true) { _, size in screenSize = size }
            // Keys and dials claim their touches, so the pinch is watched at the window.
            .background(PinchCatcher(enabled: controllerInFront && !heldTalk && !talkGestureActive && !store.isRecording && !store.isFinalizing) { pinched($0, in: geometry.size) })
            .scrollBounceBehavior(.basedOnSize)
            .background(GenesisBackdrop(color: slotColor, theme: theme))
            .foregroundStyle(GenesisPalette.text)
        }
        .statusBarHidden(fullScreenController)
        .persistentSystemOverlays(fullScreenController ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) { SettingsScreen(store: store, endDemo: endDemo) }
        .sheet(isPresented: $showGuide) { ConnectGuide(store: store, startDemo: startDemo) }
        .onAppear {
            // An unpaired controller starts with how to connect, once per launch.
            if !store.isDemo, store.hosts.isEmpty, !GuideLaunch.offered { GuideLaunch.offered = true; showGuide = true }
        }
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
        .sheet(isPresented: $showThread) { threadSheet }
        .sheet(isPresented: $showGlassesControls) { glassesControls }
        // A pane or toggle takes the thread over in these layouts; a sheet left open would show it twice.
        .onChange(of: threadInPlace) { _, inPlace in if inPlace { showThread = false } }
        .sheet(item: Binding(get: { quickMappingIndex.map { MappingSelection(id:$0) } }, set: { quickMappingIndex = $0?.id })) { selection in
            ActionBrowser(store:store,quickKey:selection.id)
        }
        .sheet(item: Binding(get: { mappingIndex.map { MappingSelection(id: $0) } }, set: { mappingIndex = $0?.id })) { selection in
            MappingScreen(store: store, index: selection.id)
        }
        // A press that cannot act yet: what it needs, and a button for the next step when there is one.
        .alert(store.hint?.title ?? "", isPresented: Binding(get: { store.hint != nil }, set: { if !$0 { store.hint = nil } }), presenting: store.hint) { hint in
            if let step = hint.step, let label = hint.stepLabel {
                Button(label) { ControllerSound.shared.keyClick(); store.hint = nil; take(step) }
                Button("Not now", role: .cancel) { ControllerSound.shared.keyClick(); store.hint = nil }
            } else {
                Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.hint = nil }
            }
        } message: { hint in Text(hint.message) }
        .alert("Controller update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil; store.macDraftBlocksSend = false } })) {
            if store.macDraftBlocksSend {
                // The one case with a way forward from here, and it throws away text on the Mac, so it is asked for.
                Button("Replace it and send", role: .destructive) {
                    ControllerSound.shared.keyClick(); store.lastError = nil
                    Task { await store.sendDraft(replacingMacDraft: true) }
                }
                Button("Leave it", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil; store.macDraftBlocksSend = false }
            } else {
                Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil }
            }
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

    private func setFullScreen(_ enabled: Bool) { setSize(enabled ? .focused : .dashboard) }

    private func setSize(_ size: ControllerSize, pinching: Bool = false) {
        // A pinch's fingers may land on a dial, which the pinch then cancels;
        // only talking holds the size still.
        let allowed = pinching ? !heldTalk && !talkGestureActive && !store.isRecording && !store.isFinalizing : canChangeLayout
        guard allowed, size != controllerSize else { return }
        ControllerSound.shared.keyClick()
        controllerSize = size
        guard !store.isDemo else { return }
        UserDefaults.standard.set(size.rawValue, forKey: Self.sizeKey)
        UserDefaults.standard.set(size != .dashboard, forKey: Self.fullScreenKey)
    }

    /// The size last chosen. Installs from before the deck-only size kept a yes/no.
    private static func savedSize() -> ControllerSize {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: sizeKey) as? Int).flatMap(ControllerSize.init(rawValue:))
            ?? (defaults.bool(forKey: fullScreenKey) ? .focused : .dashboard)
        return saved == .deckOnly && UIDevice.current.userInterfaceIdiom != .pad ? .focused : saved
    }

    /// The deck alone needs an iPad window with room for full-size keys.
    private func deckOnlyFits(_ size: CGSize) -> Bool {
        guard isPad, min(size.width, size.height) >= 500, !dynamicTypeSize.isAccessibilitySize else { return false }
        let plate = deckOnlyPlate(CGSize(width: size.width - 16, height: size.height - 16))
        let keyW = (plate.w - (plate.beside ? plate.displayW + plate.gap : 0) - plate.gap * 3) / 4
        let keyH = (plate.h - (plate.beside ? 0 : plate.stripH + plate.gap) - plate.gap * 3) / 4
        return keyW >= 44 && keyH >= 44
    }

    /// Where the keys and the display land when the deck alone fills a frame of this size.
    private func deckOnlyPlate(_ frame: CGSize) -> (w: CGFloat, h: CGFloat, gap: CGFloat, beside: Bool, displayW: CGFloat,
                                                    compact: Bool, stripH: CGFloat, threadFits: Bool) {
        let fw = max(0, frame.width), fh = max(0, frame.height)
        let side = min(fw, fh), scale = isPad ? max(1, side / 430) : 1, gap = 8 * scale, pad = side * 0.030
        let w = max(0, fw - (side * DeckArt.plateSide + pad) * 2)
        let h = max(0, fh - (side * DeckArt.plateTop + pad) - (side * DeckArt.plateBottom + pad))
        let beside = fw > fh
        // Six or seven controls and two pickers share the strip's top row; narrower than that, the controls take their own row.
        let compact = !beside && w < CGFloat(glassesFeature ? 5 : 4) * 48 + 432
        let room = max(0, h - gap * 4 - 44 * 4)
        return (w, h, gap, beside, beside ? min(420, max(250, w * 0.28)) : 0, compact,
                min(230, max(compact ? 215 : 150, h * 0.17)), beside || room >= (compact ? 300 : 230))
    }

    /// No sheet or alert covers the controller.
    private var controllerInFront: Bool {
        !showSettings && !showGuide && !showArtifacts && !showActions && !showNavigation && !showDraftReview && !showThread && !showGlassesControls
            && quickMappingIndex == nil && mappingIndex == nil && dialArtifactPreview == nil && store.hint == nil && store.lastError == nil
    }

    /// Pinching out steps up a size and pinching in steps back down.
    private func pinched(_ magnification: CGFloat, in size: CGSize) {
        guard controllerInFront else { return }
        if magnification > 1.2 {
            setSize(controllerSize == .dashboard ? .focused : deckOnlyFits(size) ? .deckOnly : controllerSize, pinching: true)
        } else if magnification < 0.83 {
            setSize(controllerSize == .deckOnly ? .focused : .dashboard, pinching: true)
        }
    }

    private func isWideFullScreen(_ size: CGSize) -> Bool {
        isPad && size.width >= 930 && size.width > size.height && !dynamicTypeSize.isAccessibilitySize
    }
    /// Full-screen landscape and deck only carry the thread themselves.
    private var threadInPlace: Bool {
        (controllerSize == .focused && isWideFullScreen(screenSize)) || (controllerSize == .deckOnly && deckOnlyFits(screenSize) && deckOnlyPlate(CGSize(width: screenSize.width - 16, height: screenSize.height - 16)).threadFits)
    }

    private var threadOpenButton: some View {
        Button { ControllerSound.shared.keyClick(); threadDetent = .large; showThread = true } label: {
            Image(systemName: "text.bubble").font(.system(size: 14, weight: .semibold))
                .frame(width: isPad || fullScreenController ? 44 : 32, height: isPad || fullScreenController ? 44 : 30)
        }
        .accessibilityLabel("Open thread").accessibilityIdentifier("thread.open")
    }

    private var threadSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ThreadPane(store: store, agentName: providerName, accent: slotColor)
                    .frame(minHeight: 160, maxHeight: .infinity)
                composer
                sendDraftButton
                if let error = store.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(store.selectedChat?.title ?? "Thread").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { ControllerSound.shared.keyClick(); showThread = false }
            } }
        }.presentationDetents([.medium, .large], selection: $threadDetent).presentationDragIndicator(.visible)
    }

    @ViewBuilder private func focusedLayout(in size: CGSize) -> some View {
        if isWideFullScreen(size) {
            // The square deck leaves some width over; the thread may use it, so the deck never shrinks for it.
            let deckSide = min(max(300, size.width - 372), max(300, size.height - 32))
            let rail: CGFloat = threadHidden ? 320 : min(460, max(320, size.width - 52 - deckSide))
            HStack(alignment: .center, spacing: 20) {
                deck(width: max(300, size.width - rail - 52), height: max(300, size.height - 32))
                VStack(spacing: 14) {
                    focusedRoute
                    focusedStatus(threadToggle: true)
                    recoveryButtons
                    if !threadHidden {
                        ThreadPane(store: store, agentName: providerName, accent: slotColor)
                            .frame(minHeight: 120, maxHeight: .infinity)
                    }
                    focusedDraft
                    focusedTools
                }
                .frame(width: rail, height: threadHidden ? nil : max(300, size.height - 32))
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
                focusedStatus()
                recoveryButtons
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
            if deckOnlyFits(screenSize) {
                Button { setSize(.deckOnly) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                        .genesisPanel(radius: 14)
                }
                .accessibilityLabel("Deck only")
                .accessibilityHint("Makes the controller fill the screen.")
                .accessibilityIdentifier("controller.deckOnly")
                .disabled(!canChangeLayout)
            }
            computerMenu { routeLabel(selectedComputerName, icon: "macmini") }
            providerMenu { routeLabel(providerName, icon: providerIcon(store.selectedProvider)) }
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(GenesisPalette.text)
    }

    private func computerMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(store.hosts) { host in
                Button { ControllerSound.shared.keyClick(); store.selectHost(host.id) } label: {
                    SwiftUI.Label(host.name, systemImage: host.id == store.selectedHostID ? "checkmark" : "desktopcomputer")
                }
            }
            Button("Pair a Mac", systemImage: "plus") { ControllerSound.shared.keyClick(); showSettings = true }
        } label: { label() }
        .accessibilityLabel("Choose computer").accessibilityValue(selectedComputerName)
        .accessibilityIdentifier("controller.chooseComputer")
    }

    private func providerMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach([ProviderID.codex, .claude, .muse], id: \.rawValue) { provider in
                Button {
                    ControllerSound.shared.keyClick(); store.selectProvider(provider)
                } label: {
                    SwiftUI.Label(provider == .codex ? "Codex" : provider.rawValue.capitalized,
                                  systemImage: provider == store.selectedProvider ? "checkmark" : "bubble.left")
                }
            }
        } label: { label() }
        .accessibilityLabel("Choose provider").accessibilityValue(providerName)
        .accessibilityIdentifier("controller.chooseProvider")
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
    private func focusedStatus(threadToggle: Bool = false) -> some View {
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
            if threadToggle {
                Button { ControllerSound.shared.keyClick(); threadHidden.toggle() } label: {
                    Image(systemName: threadHidden ? "text.bubble" : "text.bubble.fill").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
                }
                .foregroundStyle(GenesisPalette.dim)
                .accessibilityLabel(threadHidden ? "Show thread" : "Hide thread")
                .accessibilityIdentifier(threadHidden ? "thread.show" : "thread.hide")
            } else {
                threadOpenButton.foregroundStyle(GenesisPalette.dim)
            }
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
            if store.hasUnconfirmedSend {
                Text("Delivery unconfirmed · Open Review draft to check")
                    .font(.caption).foregroundStyle(.orange)
            } else if let receipt = store.lastReceipt {
                Text(receipt.message).font(.caption).foregroundStyle(GenesisPalette.dim).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .genesisPanel(radius: 20)
    }

    // MARK: Deck only

    /// The deck alone, filling the window, with the draft and routing on its built-in display.
    private func deckOnlyLayout(in size: CGSize) -> some View {
        deck(width: size.width - 16, height: size.height - 16, display: true)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: size.height)
    }

    /// What the built-in display shows. `strip` is the short, wide display
    /// under the keys in portrait; otherwise it is the tall one beside them.
    @ViewBuilder private func deckDisplay(wide strip: Bool, canThread: Bool = true, compact: Bool = false) -> some View {
        if strip {
            VStack(alignment: .leading, spacing: 10) {
                if compact {
                    HStack(spacing: 8) {
                        displayChat(lines: 1).frame(maxWidth: .infinity, alignment: .leading)
                        displayRoute
                        displayRefresh
                    }
                    displayTools(spread: true, canThread: canThread)
                } else {
                    HStack(spacing: 8) {
                        displayChat(lines: 1).frame(maxWidth: .infinity, alignment: .leading)
                        displayRoute
                        displayRefresh
                        displayTools(spread: false, canThread: canThread)
                    }
                }
                if !threadHidden && canThread { displayThread }
                HStack(alignment: .top, spacing: 12) {
                    displayDraft(lines: 2, grow: threadHidden || !canThread)
                    sendDraftButton
                }
            }
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) { displayRoute }
                HStack(alignment: .top, spacing: 6) {
                    displayChat(lines: 2).frame(maxWidth: .infinity, alignment: .leading)
                    displayRefresh
                }
                DisplayRule()
                if !threadHidden {
                    displayThread
                    DisplayRule()
                }
                displayDraft(lines: threadHidden ? 10 : 3, grow: threadHidden)
                sendDraftButton.frame(maxWidth: .infinity)
                DisplayRule()
                displayTools(spread: true)
            }
            .padding(14)
        }
    }

    private var displayRoute: some View {
        Group {
            computerMenu { displayChip(selectedComputerName, icon: "macmini") }
            providerMenu { displayChip(providerName, icon: providerIcon(store.selectedProvider)) }
        }
        .disabled(!canChangeLayout)
    }

    private func displayChip(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(slotColor)
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DeckDisplayPanel<EmptyView>.dim)
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(DeckDisplayPanel<EmptyView>.text)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func displayChat(lines: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(slotColor).frame(width: 8, height: 8).shadow(color: slotColor, radius: 5).padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.selectedChat?.title ?? "Choose a chat")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeckDisplayPanel<EmptyView>.text)
                    .lineLimit(lines)
                    .accessibilityIdentifier("controller.currentChat")
                HStack(spacing: 5) {
                    Circle().fill(store.providerInfo?.readiness == "ready" ? Color.green : Color.orange).frame(width: 5, height: 5)
                    Text(store.connectionMessage).lineLimit(lines)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeckDisplayPanel<EmptyView>.dim)
            }
        }
    }

    private var displayRefresh: some View {
        Button { ControllerSound.shared.keyClick(); Task { await store.refresh() } } label: {
            Group {
                if store.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)) }
            }
            .frame(width: 44, height: 44)
        }
        .foregroundStyle(DeckDisplayPanel<EmptyView>.dim)
        .accessibilityLabel("Refresh connection and chats")
    }

    /// The open chat's conversation, on the display's dark glass. It takes the height the other rows leave.
    private var displayThread: some View {
        ThreadPane(store: store, agentName: providerName, accent: slotColor,
                   style: .dark(slotColor, text: DeckDisplayPanel<EmptyView>.text, dim: DeckDisplayPanel<EmptyView>.dim))
            .frame(minHeight: 60, maxHeight: .infinity)
    }

    private func displayDraft(lines: Int, grow: Bool = true) -> some View {
        Button { ControllerSound.shared.keyClick(); showDraftReview = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.isRecording ? "LISTENING…" : store.isFinalizing ? "FINISHING…" : "DRAFT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.6)
                    .foregroundStyle(slotColor)
                Text(store.draft.isEmpty ? "Hold Talk, then release to review." : store.draft)
                    .font(.system(size: 16))
                    .lineLimit(lines)
                    .foregroundStyle(store.draft.isEmpty ? DeckDisplayPanel<EmptyView>.dim : DeckDisplayPanel<EmptyView>.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A long dictation shows its end, where the words are arriving.
                    .opacity(dictatingDraft ? 0 : 1)
                    .overlay { if dictatingDraft { LiveDraft(text: store.draft, size: 16, color: DeckDisplayPanel<EmptyView>.text) } }
                if store.hasUnconfirmedSend {
                    Text("Delivery unconfirmed · Tap to check").font(.caption).foregroundStyle(.orange)
                } else if let receipt = store.lastReceipt {
                    Text(receipt.message).font(.caption).foregroundStyle(DeckDisplayPanel<EmptyView>.dim).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: grow ? .infinity : nil, alignment: .topLeading)
            .frame(minHeight: grow ? nil : 44, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!canChangeLayout)
        .accessibilityLabel("Review draft").accessibilityIdentifier("controller.reviewDraft")
    }

    private func displayTools(spread: Bool, canThread: Bool = true) -> some View {
        HStack(spacing: spread ? 0 : 4) {
            displayTool("arrow.down.right.and.arrow.up.left", label: "Smaller controller", id: "controller.shrink", spread: spread) { setSize(.focused) }
            displayTool("square.grid.2x2", label: "Actions", id: "controller.actions", spread: spread) { ControllerSound.shared.keyClick(); showActions = true }
            if glassesFeature {
                DisplayGlassesButton(follow: store.glasses) { ControllerSound.shared.keyClick(); showGlassesControls = true }
                    .frame(maxWidth: spread ? .infinity : nil)
            }
            if canThread {
                displayTool(threadHidden ? "text.bubble" : "text.bubble.fill", label: threadHidden ? "Show thread" : "Hide thread",
                            id: threadHidden ? "thread.show" : "thread.hide", spread: spread) { ControllerSound.shared.keyClick(); threadHidden.toggle() }
            } else {
                // No room for the thread on the display at this window size: it opens as a sheet.
                displayTool("text.bubble", label: "Open thread", id: "thread.open", spread: spread) {
                    ControllerSound.shared.keyClick(); threadDetent = .large; showThread = true
                }
            }
            displayTool("slider.horizontal.3", label: "Settings and Mac pairing", id: "controller.settings", spread: spread) { ControllerSound.shared.keyClick(); showSettings = true }
        }
        .disabled(!canChangeLayout)
    }

    private func displayTool(_ icon: String, label: String, id: String, spread: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .foregroundStyle(DeckDisplayPanel<EmptyView>.text)
        .frame(maxWidth: spread ? .infinity : nil)
        .accessibilityLabel(label).accessibilityIdentifier(id)
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
        if let notice = store.companionNotice {
            Label(notice, systemImage: "arrow.down.circle")
                .font(.system(size: isPad ? 13 : 11, weight: .medium)).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 7)
                .accessibilityIdentifier("controller.companionNotice")
        }
        recoveryButtons
    }

    /// Ways out of a state only the Mac can fix, offered wherever the deck is shown.
    @ViewBuilder private var recoveryButtons: some View {
        if store.providerInfo?.supports("launchApp") == true {
            // The app is installed but shut. Someone away from the Mac can open it from here.
            Button {
                ControllerSound.shared.keyClick()
                Task { await store.openProviderApp() }
            } label: {
                Label(store.providerNeedsWiderWindow ? "Widen \(store.selectedProvider.name)’s window on \(selectedComputerName)" : "Open \(store.selectedProvider.name) on \(selectedComputerName)",
                      systemImage: store.providerNeedsWiderWindow ? "arrow.left.and.right" : "arrow.up.forward.app")
                    .font(.system(size: isPad ? 14 : 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: isPad ? 46 : 40)
                    .genesisPanel(radius: 13, raised: true)
            }
            .disabled(!store.canOpenProviderApp)
            .accessibilityIdentifier("controller.openApp")
        }
        if store.providerInfo?.supports("restartService") == true {
            // The app's background service lost its connection. Someone away from the Mac can restart it from here.
            Button {
                ControllerSound.shared.keyClick()
                Task { await store.restartProviderService() }
            } label: {
                Label("Restart \(store.selectedProvider.name) service on \(selectedComputerName)", systemImage: "arrow.clockwise.circle")
                    .font(.system(size: isPad ? 14 : 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: isPad ? 46 : 40)
                    .genesisPanel(radius: 13, raised: true)
            }
            .disabled(!store.canRestartProviderService)
            .accessibilityIdentifier("controller.restartService")
        }
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
        showDraftReview = false; showThread = false; showGlassesControls = false
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
                    Button { ControllerSound.shared.keyClick(); if store.isDemo { showSettings = true } else { showGuide = true } } label: {
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
            threadOpenButton
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
    /// Does what a hint's button offers.
    private func take(_ step: ControllerHint.Step) {
        switch step {
        case .assignKey(let index): dialSlot = index; mappingIndex = index
        case .writeDraft:
            // Full screen keeps the draft in its review sheet; the main layout has the box on screen.
            if fullScreenController { showDraftReview = true } else { draftFocused = true }
        case .reviewSend: showDraftReview = true
        case .pairMac: if store.isDemo { showSettings = true } else { showGuide = true }
        case .openApp: Task { await store.openProviderApp() }
        case .restartService: Task { await store.restartProviderService() }
        case .refresh: Task { await store.refresh() }
        }
    }

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

    /// Draws the deck. With `display`, it fills the whole frame and carries
    /// the built-in display: beside the keys when wide, under them when tall.
    /// The built-in display is passed as `AnyView`. Spelled out, its type nests so deep that
    /// instantiating the deck overflowed the main thread's stack at launch on a real iPhone;
    /// simulators have a larger stack and did not show it.
    private func deck(width: CGFloat, height: CGFloat, display: Bool = false) -> some View {
        let fit = display ? CGSize(width: max(0, width), height: max(0, height)) : deckFit(width: width, height: height)
        let side = min(fit.width, fit.height)
        let scale = isPad ? max(1, side / 430) : 1
        let gap: CGFloat = 8 * scale
        // Keys sit on the rendered plate, inside the rim. The rim's size is
        // fixed by the render's scale, which follows the deck's shorter side.
        let pad = side * 0.030
        let left = side * DeckArt.plateSide + pad
        let top = side * DeckArt.plateTop + pad
        let bottom = side * DeckArt.plateBottom + pad
        let wall = side * DeckArt.frontWall
        let plateW = max(0, fit.width - left * 2), plateH = max(0, fit.height - top - bottom)
        let beside = display && fit.width > fit.height
        let displayW = beside ? min(420, max(250, plateW * 0.28)) : 0
        // The thread needs room: a taller strip, never so tall that a key drops under 44 points.
        let strip = deckOnlyPlate(fit)
        let threadH = min(460, max(strip.compact ? 330 : 260, plateH * 0.36)), roomH = max(0, plateH - gap * 4 - 44 * 4)
        let stripThread = !threadHidden && strip.threadFits
        let displayH = display && !beside ? (stripThread ? min(threadH, roomH) : strip.stripH) : 0
        let keyW = max(0, (plateW - (beside ? displayW + gap : 0) - gap * 3) / 4)
        let keyH = max(0, (plateH - (displayH > 0 ? displayH + gap : 0) - gap * 3) / 4)
        // The knob in use glows as hard as its key.
        let chatDialLevel = store.selectedSlotIndex == nil ? 0.30 : browsedSlot == store.selectedSlotIndex ? 1.0 : 0.62
        let browsingUnopened = dialSlot != nil && dialSlot != store.selectedSlotIndex
        return ZStack {
            DeckChassis(glow: slotColor, scale: scale, theme: theme, unit: side)
            VStack(spacing: gap) {
              HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        DialControl(silver: true, caption: "CHATS", color: theme.accent(store.activity(slot: browsedSlot), 0), level: chatDialLevel, ringSelection: browsedSlot,
                                    ringColors: (0..<6).map { GenesisPalette.dot(store.activity(slot: $0)) },
                                    degreesPerStep: 60, restingRotation: $chatDialRotation, scale: scale,
                                    interactionChanged: { chatDialActive = $0 },
                                    selectionDescription: "\(slotPrefix)\(browsedSlot + 1), \(slotTitle(browsedSlot))",
                                    visibleSelection: browsingUnopened ? "PRESS TO OPEN" : nil, turn: { delta in
                            dialSlot = ((browsedSlot + delta) % 6 + 6) % 6
                        }, press: { activateSlot(browsedSlot) }).frame(width: keyW, height: keyH)
                        slot(0, width: keyW, height: keyH, scale: scale)
                        slot(1, width: keyW, height: keyH, scale: scale)
                        DialControl(silver: false, caption: "ARTIFACTS", color: theme.accent(deckActivity, 1), restingRotation: $artifactDialRotation, scale: scale,
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
                            // Resting, the Home light plays the theme; with a chat that has something to say, it shows that.
                            PixelLight(color: theme.accent(deckActivity, 2), working: store.isBusy, reduceMotion: reduceMotion, scale: scale,
                                       idleColors: deckActivity == nil || deckActivity == .idle ? theme.colors : [])
                        }
                        .buttonStyle(HomePuckStyle(color: theme.accent(deckActivity, 2), caption: "HOME", scale: scale))
                        .frame(width: keyW, height: keyH)
                        .accessibilityLabel("Return to chat selection")
                        talkKey(width: keyW * 2 + gap, height: keyH, scale: scale)
                        actionKey("Map", icon: "slider.horizontal.3", width: keyW, height: keyH, scale: scale, enabled: true) { mappingIndex = browsedSlot }
                    }
                }
                if beside { DeckDisplayPanel(content: AnyView(deckDisplay(wide: false)), color: slotColor).frame(width: displayW, height: plateH) }
              }
              if displayH > 0 { DeckDisplayPanel(content: AnyView(deckDisplay(wide: true, canThread: strip.threadFits, compact: strip.compact)), color: slotColor).frame(width: plateW, height: displayH) }
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
        let assigned = store.profile.slots.contains { $0.index == index && $0.kind != "empty" }
        // The light says what the chat is doing, not which key it is. Only a working chat pulses.
        let activity = selected ? store.selectedActivity : store.activity(slot: index)
        let color = GenesisPalette.light(activity)
        let base = GenesisPalette.level(activity, assigned: assigned)
        return HoldTapKeycap(led: color, level: min(1, base + (selected ? 0.18 : browsed ? 0.10 : 0)), breathing: activity == .thinking, scale: scale, unit: width,
                             tap: { activateSlot(index) },
                             hold: { ControllerSound.shared.keyClick(); mappingIndex = index }) {
            VStack(spacing: 4 * scale) {
                HStack(spacing: 4 * scale) {
                    Circle().fill(GenesisPalette.dot(activity))
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
                if selected {
                    // The open chat: a solid ring, now that color no longer marks it.
                    RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                        .strokeBorder(GenesisPalette.ink.opacity(0.78), lineWidth: 1.6 * scale)
                        .padding(-3 * scale)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if browsed {
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
            .accessibilityValue(([activity?.label] + [selected && browsed ? "Current chat, dial selection" : selected ? "Current chat" : browsed ? "Dial selection" : nil]).compactMap { $0 }.joined(separator: ", "))
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
        .buttonStyle(KeycapButtonStyle(led: capColor, level: active ? 1 : enabled ? 0.10 : 0.03, scale: scale, unit: width))
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
        return HoldTapKeycap(led: capColor, level: armed ? 0.85 : waiting ? 0.60 : enabled ? 0.10 : 0.03, scale: scale, unit: width,
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
            store.hint = store.hint(forAction: id)
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
            if reason != nil { store.hint = store.hint(forAction: "dictate") }
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
        Keycap(led: capColor, level: store.isRecording ? 1 : store.canDictate ? 0.13 : 0.03, breathing: store.isRecording,
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
                else { ControllerSound.shared.keyClick(); store.hint = store.hint(forAction: "dictate") }
            }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: isPad ? 12 : 9) {
            HStack {
                Circle().fill(slotColor).frame(width: 7, height: 7).shadow(color: slotColor, radius: 5)
                Text(store.selectedChat?.title ?? "Choose a chat to begin").font(.system(size: isPad ? 17 : 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if let activity = store.selectedActivity, activity != .idle {
                    Text(activity.label).font(.system(size: isPad ? 12 : 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(GenesisPalette.light(activity)))
                        .accessibilityIdentifier("controller.activity")
                }
                Text(providerName).font(isPad ? .caption : .caption2).foregroundStyle(GenesisPalette.dim)
            }
            TextField(codexDraftOnly ? "Local draft — Send is not connected yet" : "Hold the microphone, or type a draft…", text: $store.draft, axis: .vertical)
                .focused($draftFocused)
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
            if store.hasUnconfirmedSend {
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
    var color: Color = GenesisPalette.text
    var body: some View {
        ScrollView(.vertical) {
            Text(text).font(.system(size: size)).foregroundStyle(color)
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
    var ringColors: [Color] = []
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
                DialKnob(finish: silver ? .snow : .graphite, color: color, level: level, ringSelection: ringSelection, ringColors: ringColors,
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

/// Whether the connect guide has opened by itself since the app launched.
@MainActor enum GuideLaunch { static var offered = false }

/// The controller's three sizes. Deck only is iPad-only.
enum ControllerSize: Int {
    case dashboard = 0, focused = 1, deckOnly = 2
}

/// The built-in display: dark glass set into the plate, lit at its edge by the deck's color.
private struct DeckDisplayPanel<Content: View>: View {
    static var text: Color { Color(white: 0.94) }
    static var dim: Color { Color(white: 0.62) }
    let content: Content
    let color: Color

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.07), Color(red: 0.08, green: 0.09, blue: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        // Recessed: a shadow along the inside of the top edge.
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.7), lineWidth: 4).blur(radius: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 1.5)
            }
            .shadow(color: color.opacity(0.22), radius: 12)
            .environment(\.colorScheme, .dark)
    }
}

private struct DisplayRule: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }
}

private struct DisplayGlassesButton: View {
    @ObservedObject var follow: GlassesFollowController
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Image(systemName: "eyeglasses").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                .background((follow.acknowledged ? Color.green.opacity(0.28) : Color.white.opacity(0.07)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .foregroundStyle(follow.acknowledged ? Color.green : Color(white: 0.94))
        .accessibilityLabel("Glasses")
        .accessibilityValue(follow.acknowledged ? "Synced" : follow.connecting ? "Connecting" : follow.enabled ? "Waiting" : "Off")
        .accessibilityIdentifier("controller.glasses")
    }
}

/// Reports a finished two-finger pinch anywhere in the window. A pinch that
/// is recognized cancels the touches under it, so it never presses a key.
private struct PinchCatcher: UIViewRepresentable {
    /// Off while a sheet is up, so it never takes touches from what is in front.
    let enabled: Bool
    let ended: (CGFloat) -> Void

    func makeUIView(context: Context) -> CatcherView { CatcherView() }
    func updateUIView(_ view: CatcherView, context: Context) { view.ended = ended; view.watching = enabled }

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        var ended: ((CGFloat) -> Void)?
        var watching = true { didSet { pinch.isEnabled = watching } }
        private lazy var pinch: UIPinchGestureRecognizer = {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handle(_:)))
            pinch.delegate = self
            return pinch
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            window?.removeGestureRecognizer(pinch)
            newWindow?.addGestureRecognizer(pinch)
        }

        @objc private func handle(_ pinch: UIPinchGestureRecognizer) {
            if pinch.state == .ended { ended?(pinch.scale) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
