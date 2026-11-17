import SwiftUI
import AVFoundation
import UIKit

struct SettingsScreen: View {
    @ObservedObject var store: ControllerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("controllerSoundsEnabled") private var controllerSoundsEnabled = true
    @AppStorage(ControllerSound.packKey) private var soundPack = ControllerSound.defaultPack.id
    @AppStorage(ControllerSound.volumeKey) private var soundVolume = ControllerSound.defaultVolume
    @State private var pairingLink = ""
    @State private var scanning = false
    @State private var pairing = false
    @State private var message: String?

    private var selectedPack: ControllerSound.Pack {
        ControllerSound.packs.first { $0.id == soundPack } ?? ControllerSound.defaultPack
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Genesis Agent Micro Controller", systemImage: "circle.grid.3x2.fill")
                    Text("Your controller, wherever you work.").foregroundStyle(.secondary)
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
                    Text("On the Mac, click the Genesis dial in the menu bar, then Pair iPhone / Artifacts. Scan its private pairing code while both devices are connected to Tailscale.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { ControllerSound.shared.keyClick(); scanning = true } label: { Label("Scan pairing code", systemImage: "qrcode.viewfinder") }
                    TextField("Or paste a private pairing link", text: $pairingLink).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Button(pairing ? "Connecting…" : "Pair this Mac") { ControllerSound.shared.keyClick(); pair(pairingLink) }.disabled(pairing || pairingLink.isEmpty)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
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
                }
                Section("How it works") {
                    Label("Hold Talk, release to review, tap Send.", systemImage: "mic")
                    Label("Long-press any key to change its assignment.", systemImage: "hand.tap")
                    Label("Drafts stay with their Mac and chat.", systemImage: "text.bubble")
                    Text("Live voice appears when the selected provider supports verified two-way phone audio. A connected Mac may still need its app opened or its screen unlocked.")
                        .font(.caption).foregroundStyle(.secondary)
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
            do { try await store.pair(url); pairingLink = ""; message = "Paired. Your Mac is ready in the switcher." }
            catch { message = error.localizedDescription }
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
    private var prefix: String { store.selectedProvider == .codex ? "A" : store.selectedProvider == .claude ? "C" : "M" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle().fill(GenesisPalette.color(index)).frame(width: 16, height: 16)
                        Text("\(prefix)\(index + 1)").font(.title2.bold())
                        Text("Chat or shortcut").foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("\(store.selectedProvider.name) chats on \(store.selectedHost?.name ?? "this Mac")") {
                    if store.navigationOnly {
                        Text(store.providerInfo?.supportsPhoneDictation == true
                             ? "Chat switching, phone dictation drafts, and artifacts are available. Send is not connected for this provider yet."
                             : "Chat switching and artifacts are available. Send is not connected for this provider yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.chats.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { chat in
                        Button { ControllerSound.shared.keyClick(); save(kind: "chat", title: chat.title, id: chat.id) } label: {
                            Label(chat.title, systemImage: "bubble.left.and.bubble.right")
                        }.disabled(!store.canMapChats)
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
        Task { let saved = await store.saveSlot(SlotMapping(index: index, kind: kind, title: title, targetID: id)); saving = false; if saved { dismiss() } }
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
    private let cameraQueue = DispatchQueue(label: "genesis.qr.camera")
    init(completion: @escaping (String) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let label = instructionLabel; label.text = "Scan your Mac’s Genesis pairing code"; label.textColor = .white; label.textAlignment = .center
        label.numberOfLines = 0; label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else { label.text = "Camera access is off. Close this sheet and paste the pairing link instead."; return }
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
        guard code.hasPrefix("genesiscontroller://pair?") else { return }
        stop(); completion(code)
    }
}
