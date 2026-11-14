import SwiftUI
import AVFoundation
import UIKit

struct SettingsScreen: View {
    @ObservedObject var store: ControllerStore
    @Environment(\.dismiss) private var dismiss
    @State private var pairingLink = ""
    @State private var scanning = false
    @State private var pairing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Genesis Agent Micro Controller", systemImage: "circle.grid.3x2.fill")
                    Text("Your controller, wherever you work.").foregroundStyle(.secondary)
                }
                Section("Pair a Mac") {
                    Text("On the Mac, click the Genesis dial in the menu bar, then Pair iPhone / Artifacts. Scan its private pairing code while both devices are connected to Tailscale.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { scanning = true } label: { Label("Scan pairing code", systemImage: "qrcode.viewfinder") }
                    TextField("Or paste a private pairing link", text: $pairingLink).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Button(pairing ? "Connecting…" : "Pair this Mac") { pair(pairingLink) }.disabled(pairing || pairingLink.isEmpty)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Your Macs") {
                    ForEach(store.hosts) { host in
                        Button {
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
                    Button("Refresh") { Task { await store.refresh() } }
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScanner { code in scanning = false; pairingLink = code; pair(code) }
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
                        Text("Chat switching and artifacts are available. Talk, Send, Stop, and live Voice are not available for this provider yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.chats.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { chat in
                        Button { save(kind: "chat", title: chat.title, id: chat.id) } label: {
                            Label(chat.title, systemImage: "bubble.left.and.bubble.right")
                        }.disabled(!store.canMapChats)
                    }
                    if store.chats.isEmpty || !store.canMapChats {
                        Text(store.chatAvailabilityMessage).font(.caption).foregroundStyle(.secondary)
                    } else if !query.isEmpty && !store.chats.contains(where: { $0.title.localizedCaseInsensitiveContains(query) }) {
                        Text("No chats match your search.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { Task { await store.refresh() } } label: {
                        Label(store.canMapChats ? "Refresh chats" : "Refresh connection", systemImage: "arrow.clockwise")
                    }.disabled(!store.isPaired || store.isRefreshingChats)
                }
                ActionCatalogSections(store: store, query: query) { action in save(kind:"action",title:action.title,id:action.id) }
                Section { Button("Remove assignment", role: .destructive) { save(kind: "empty", title: "Unassigned", id: "") } }
            }.disabled(saving).searchable(text: $query, prompt: "Search chats and actions")
                .navigationTitle("Map \(prefix)\(index + 1)")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
    private let cameraQueue = DispatchQueue(label: "genesis.qr.camera")
    init(completion: @escaping (String) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let label = UILabel(); label.text = "Scan your Mac’s Genesis pairing code"; label.textColor = .white; label.textAlignment = .center
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
        guard !done, let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }; session.addOutput(output)
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
