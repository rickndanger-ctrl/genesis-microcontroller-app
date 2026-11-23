import SwiftUI
import AVFoundation
import UIKit

struct SettingsScreen: View {
    @AppStorage(DeckTheme.storageKey) private var themeID = DeckTheme.aurora.rawValue
    @ObservedObject var store: ControllerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("controllerSoundsEnabled") private var controllerSoundsEnabled = true
    @AppStorage(ControllerSound.packKey) private var soundPack = ControllerSound.defaultPack.id
    @AppStorage(ControllerSound.volumeKey) private var soundVolume = ControllerSound.defaultVolume
    @AppStorage private var glassesFeature: Bool
    @State private var pairingLink = ""
    @State private var scanning = false
    @State private var pairing = false
    @State private var message: String?
    @State private var offerSettings = false

    private var selectedPack: ControllerSound.Pack {
        ControllerSound.packs.first { $0.id == soundPack } ?? ControllerSound.defaultPack
    }

    /// Leaves the in-app demo, when that is what this is.
    private let endDemo: (() -> Void)?

    init(store: ControllerStore, endDemo: (() -> Void)? = nil) {
        self.store = store
        self.endDemo = endDemo
        _glassesFeature = AppStorage(wrappedValue: false, GlassesFeature.storageKey(demo: store.isDemo))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Agent Micro Controller", systemImage: "circle.grid.3x2.fill")
                    Text("Your controller, wherever you work.").foregroundStyle(.secondary)
                    if let endDemo {
                        Button("Exit demo", systemImage: "xmark.circle") { ControllerSound.shared.keyClick(); endDemo() }
                            .accessibilityIdentifier("settings.exitDemo")
                    }
                }
                Section("Controller") {
                    Toggle("Controller sounds", isOn: Binding(get: { controllerSoundsEnabled }, set: { enabled in
                        guard enabled != controllerSoundsEnabled else { return }
                        controllerSoundsEnabled = enabled
                        // Enabling previews one click; disabling is immediately quiet.
                        if enabled { ControllerSound.shared.keyClick() }
                    }))
                    if controllerSoundsEnabled {
                        NavigationLink {
                            ClickSoundScreen()
                        } label: {
                            LabeledContent("Click sound", value: "\(selectedPack.title) · \(Int((soundVolume * 100).rounded()))%")
                        }
                    }
                    Text("Clicks for keys and dial detents. Muted while dictating.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Pair a Mac") {
                    Text("On your Mac, open Agent Micro Controller and choose Set Up and Pair a Phone from its dial in the menu bar. Scan the code with this device on the same Wi-Fi as the Mac. To use the Mac away from home, also set up Tailscale on both.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { ControllerSound.shared.keyClick(); scanning = true } label: { Label("Scan pairing code", systemImage: "qrcode.viewfinder") }
                    TextField("Or paste a private pairing link", text: $pairingLink).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Button(pairing ? "Connecting…" : "Pair this Mac") { ControllerSound.shared.keyClick(); pair(pairingLink) }.disabled(pairing || pairingLink.isEmpty)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if offerSettings { Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } }
                }
                Section("Your Macs") {
                    ForEach(store.hosts) { host in
                        Button {
                            ControllerSound.shared.keyClick()
                            store.selectHost(host.id); dismiss()
                        } label: {
                            HStack {
                                Image(systemName: host.name.lowercased().contains("neo") ? "laptopcomputer" : "macmini")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.name)
                                    Text(host.baseURL).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if host.id == store.selectedHostID { Image(systemName: "checkmark") }
                            }.padding(.vertical, 3)
                        }
                    }
                }
                Section("Connection") {
                    Text(store.connectionMessage)
                    if let info = store.providerInfo {
                        Text(info.reason ?? "Select a mapped chat to begin.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Refresh") { ControllerSound.shared.keyClick(); Task { await store.refresh() } }
                    if let notice = store.companionNotice {
                        Label(notice, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.orange)
                    }
                    if store.isPaired {
                        NavigationLink { DiagnosticsScreen(store: store) } label: {
                            Label("Check \(store.selectedHost?.name ?? "this Mac")", systemImage: "stethoscope")
                        }
                        .accessibilityIdentifier("settings.diagnostics")
                    }
                }
                Section {
                    ForEach(DeckTheme.allCases) { theme in
                        Button { ControllerSound.shared.keyClick(); themeID = theme.rawValue } label: {
                            HStack(spacing: 12) {
                                HStack(spacing: -5) {
                                    ForEach(0..<3, id: \.self) { index in
                                        Circle().fill(theme.color(index)).frame(width: 18, height: 18)
                                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.name).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                    Text(theme.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if themeID == theme.rawValue { Image(systemName: "checkmark").font(.callout.weight(.semibold)) }
                            }
                        }
                        .accessibilityIdentifier("settings.theme.\(theme.rawValue)")
                        .accessibilityAddTraits(themeID == theme.rawValue ? .isSelected : [])
                    }
                } header: { Text("Deck theme") } footer: {
                    Text("Colors the glow under the deck, the knobs and the Home light. The six chat keys are never themed: their color always means what the chat is doing.")
                }
                Section {
                    ForEach(ChatActivity.allCases, id: \.self) { activity in
                        HStack(spacing: 12) {
                            Circle().fill(GenesisPalette.dot(activity)).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
                            Text(activity.label).font(.callout.weight(.semibold)).frame(width: 96, alignment: .leading)
                            Text(activity.meaning).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: { Text("Key lights") } footer: {
                    Text("Each chat key shows what its chat is doing on the Mac. A working chat pulses. The open chat has a ring around its key.")
                }
                .accessibilityIdentifier("settings.keyLights")
                Section("Glasses") {
                    Toggle("Even G2 glasses (experimental)", isOn: Binding(get: { glassesFeature }, set: { enabled in
                        guard enabled != glassesFeature else { return }
                        ControllerSound.shared.keyClick()
                        // Hiding the controls must not leave Follow running unseen.
                        if !enabled, store.glasses.enabled { store.glasses.stop() }
                        glassesFeature = enabled
                    }))
                    .accessibilityIdentifier("settings.glasses")
                    Text("Shows Follow this controller, which mirrors your chat and draft on Even Realities G2 glasses. It needs the separate, do-it-yourself Genesis G2 add-on on your Macs and Tailscale on the phone running Even. Leave it off if you don’t have the glasses.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://rickndanger-ctrl.github.io/agent-micro-controller-site/glasses/")!) {
                        Label("Glasses setup guide", systemImage: "eyeglasses")
                    }
                    .accessibilityIdentifier("settings.glassesGuide")
                }
                Section("How it works") {
                    Label("Hold Talk, release to review, tap Send.", systemImage: "mic")
                    Label("Long-press any key to change its assignment.", systemImage: "hand.tap")
                    Label("Drafts stay with their Mac and chat.", systemImage: "text.bubble")
                    Text("Live voice appears when the selected provider supports verified two-way phone audio. A connected Mac may still need its app opened or its screen unlocked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy & support") {
                    Link(destination: URL(string: "https://rickndanger-ctrl.github.io/agent-micro-controller-site/privacy/")!) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://rickndanger-ctrl.github.io/agent-micro-controller-site/")!) {
                        Label("Help & support", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Your controller")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { ControllerSound.shared.keyClick(); dismiss() } } }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner { code in scanning = false; pairingLink = code; pair(code) }
                        .navigationTitle("Scan pairing code")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { ControllerSound.shared.keyClick(); scanning = false } } }
                }
            }
        }
    }

    private func pair(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { message = "That pairing link is not valid."; return }
        pairing = true
        Task {
            defer { pairing = false }
            offerSettings = false
            do { try await store.pair(url); pairingLink = ""; message = "Paired. Your Mac is ready in the switcher." }
            catch {
                message = ConnectionHelp.describe(error, mac: nil)
                offerSettings = ConnectionHelp.problem(error).map(ConnectionHelp.fixedInSettings) ?? false
            }
        }
    }
}

/// Volume and the choice of click pack. Every change is auditioned at once.
struct ClickSoundScreen: View {
    @AppStorage(ControllerSound.packKey) private var soundPack = ControllerSound.defaultPack.id
    @AppStorage(ControllerSound.volumeKey) private var soundVolume = ControllerSound.defaultVolume

    private var selectedPackID: String {
        ControllerSound.packs.contains { $0.id == soundPack } ? soundPack : ControllerSound.defaultPack.id
    }

    var body: some View {
        Form {
            Section("Volume") {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $soundVolume, in: 0.1...1, step: ControllerSound.volumeStep) { editing in
                        // One click at the new level when the thumb is released.
                        if !editing { ControllerSound.shared.keyClick() }
                    }
                    .accessibilityLabel("Click volume")
                    .accessibilityValue("\(Int((soundVolume * 100).rounded())) percent")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Text("Loudness also follows this device's ringer volume and silent mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sound") {
                ForEach(ControllerSound.packs) { pack in
                    Button {
                        soundPack = pack.id
                        ControllerSound.shared.keyClick()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.title).foregroundStyle(Color.primary)
                                Text(pack.detail).font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if pack.id == selectedPackID { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }.contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(pack.title) click sound")
                    .accessibilityHint(pack.detail)
                    .accessibilityAddTraits(pack.id == selectedPackID ? .isSelected : [])
                }
            }
            Section {
                Button { ControllerSound.shared.keyClick() } label: { Label("Play the key click", systemImage: "square.fill") }
                Button { ControllerSound.shared.dialTick() } label: { Label("Play the dial tick", systemImage: "dial.medium") }
            }
        }
        .navigationTitle("Click sound")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MappingScreen: View {
    @ObservedObject var store: ControllerStore
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var saving = false
    /// Why the last change did not save. Shown here: an alert behind this sheet would never be seen.
    @State private var failure: String?
    private var prefix: String { store.selectedProvider.slotPrefix }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle().fill(GenesisPalette.dot(store.activity(slot: index))).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
                        Text("\(prefix)\(index + 1)").font(.title2.bold())
                        Text("Chat or shortcut").foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red)
                            .accessibilityIdentifier("slot.saveFailure")
                    }
                }
                Section("\(store.selectedProvider.name) chats on \(store.selectedHost?.name ?? "this Mac")") {
                    if store.navigationOnly {
                        Text(store.providerInfo?.supportsPhoneDictation == true
                             ? "Chat switching, phone dictation drafts, and artifacts are available. Send is not connected for this provider yet."
                             : "Chat switching and artifacts are available. Send is not connected for this provider yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.chats.filter { $0.state != "New" && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { chat in
                        Button { ControllerSound.shared.keyClick(); save(kind: "chat", title: chat.title, id: chat.id) } label: {
                            Label(chat.title, systemImage: "bubble.left.and.bubble.right")
                        }.disabled(!store.canMapChats)
                    }
                    if store.canMapChats, query.isEmpty, let notice = store.leftOutChatsNotice {
                        Label(notice, systemImage: "square.on.square.dashed").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("slot.leftOutChats")
                    }
                    if store.chats.isEmpty || !store.canMapChats {
                        Text(store.chatAvailabilityMessage).font(.caption).foregroundStyle(.secondary)
                    } else if !query.isEmpty && !store.chats.contains(where: { $0.title.localizedCaseInsensitiveContains(query) }) {
                        Text("No chats match your search.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { ControllerSound.shared.keyClick(); Task { await store.refresh() } } label: {
                        Label(store.canMapChats ? "Refresh chats" : "Refresh connection", systemImage: "arrow.clockwise")
                    }.disabled(!store.isPaired || store.isRefreshingChats)
                }
                ActionCatalogSections(store: store, query: query) { action in save(kind:"action",title:action.title,id:action.id) }
                Section { Button("Remove assignment", role: .destructive) { ControllerSound.shared.keyClick(); save(kind: "empty", title: "Unassigned", id: "") } }
            }.disabled(saving).searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats and actions")
                .navigationTitle("Map \(prefix)\(index + 1)")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { ControllerSound.shared.keyClick(); dismiss() } } }
        }
    }

    private func save(kind: String, title: String, id: String) {
        saving = true
        failure = nil
        Task {
            let saved = await store.saveSlot(SlotMapping(index: index, kind: kind, title: title, targetID: id)); saving = false
            if saved { dismiss() } else { failure = store.lastError ?? "This key could not be changed. Check the connection to your Mac and try again." }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let completion: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerViewController { ScannerViewController(completion: completion) }
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) { uiViewController.stop() }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let completion: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    private let instructionLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    private let cameraQueue = DispatchQueue(label: "genesis.qr.camera")
    init(completion: @escaping (String) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let label = instructionLabel; label.text = "Scan your Mac’s pairing code"; label.textColor = .white; label.textAlignment = .center
        label.numberOfLines = 0; label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        settingsButton.setTitle("Open Settings", for: .normal); settingsButton.isHidden = true
        settingsButton.accessibilityIdentifier = "scanner.openSettings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(settingsButton)
        settingsButton.addAction(UIAction { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([settingsButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16), settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    label.text = "Camera access is off. Allow it in Settings to scan, or paste the pairing link in this app’s settings."
                    self.settingsButton.isHidden = false; return
                }
                self.configure()
            }
        }
    }
    private func configure() {
        guard !done else { return }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            instructionLabel.text = "The camera is unavailable. Tap Cancel and paste the pairing link instead."
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            instructionLabel.text = "The scanner is unavailable. Tap Cancel and paste the pairing link instead."
            return
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            instructionLabel.text = "QR scanning is unavailable. Tap Cancel and paste the pairing link instead."
            return
        }
        output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; self.preview = preview
        view.layer.insertSublayer(preview, at: 0); preview.frame = view.bounds
        cameraQueue.async { [session] in session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { done = true; cameraQueue.async { [session] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        guard code.hasPrefix("genesiscontroller://pair?") else {
            instructionLabel.text = "That isn’t a pairing code. Scan the one in the Mac’s setup window."; return
        }
        stop(); completion(code)
    }
}
