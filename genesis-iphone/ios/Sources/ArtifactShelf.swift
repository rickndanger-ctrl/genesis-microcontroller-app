import SwiftUI
import WebKit
import QuickLook

struct ArtifactShelf: View {
    @ObservedObject var store: ControllerStore
    var initialIndex = 0
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ArtifactRecord?
    @State private var query = ""
    @State private var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "genesis.artifactPins") ?? [])

    private func pinKey(_ artifact: ArtifactRecord) -> String { "\(artifact.hostID)/\(artifact.provider)/\(artifact.id)" }
    var body: some View {
        NavigationStack {
            Group {
                if store.artifacts.isEmpty {
                    ContentUnavailableView("Your artifact shelf", systemImage: "square.stack.3d.up", description: Text("Artifacts shared by this Mac appear here. Add a document, image, or app link in the Mac companion’s iPhone Remote window."))
                } else {
                    ScrollViewReader { proxy in List {
                        ForEach(store.artifacts.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted { pinned.contains(pinKey($0)) && !pinned.contains(pinKey($1)) }) { artifact in
                            Button { ControllerSound.shared.keyClick(); selected = artifact } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: artifact.kind == "web" ? "globe" : artifact.kind == "image" ? "photo" : "doc.text")
                                        .font(.title2).frame(width: 42, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) { Text(artifact.title).font(.headline); Text(artifact.kind.uppercased()).font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    if pinned.contains(pinKey(artifact)) { Image(systemName: "pin.fill").font(.caption) }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }
                            .id(artifact.id)
                            .swipeActions(edge: .leading) { Button(pinned.contains(pinKey(artifact)) ? "Unpin" : "Pin") { togglePin(artifact) }.tint(.orange) }
                            .contextMenu {
                                Button("Open on Mac", systemImage: "desktopcomputer") { ControllerSound.shared.keyClick(); Task { await store.openArtifact(artifact) } }
                                Button(pinned.contains(pinKey(artifact)) ? "Unpin" : "Pin", systemImage: "pin") { togglePin(artifact) }
                            }
                        }
                    }.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find an artifact")
                        .onAppear { if store.artifacts.indices.contains(initialIndex) { proxy.scrollTo(store.artifacts[initialIndex].id, anchor: .center) } }
                    }
                }
            }.navigationTitle("Artifacts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { ControllerSound.shared.keyClick(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { ControllerSound.shared.keyClick(); Task { await store.refreshArtifacts() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh artifacts") }
                }
                .task { await store.refreshArtifacts() }
                .sheet(item: $selected) { artifact in ArtifactPreview(store: store, artifact: artifact) }
                // A failure while this sheet is up would otherwise be reported behind it, unseen.
                .alert("Controller update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                    Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil }
                } message: { Text(store.lastError ?? "") }
        }
    }
    private func togglePin(_ artifact: ArtifactRecord) {
        ControllerSound.shared.keyClick()
        let key = pinKey(artifact); if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) }
        UserDefaults.standard.set(Array(pinned), forKey: "genesis.artifactPins")
    }
}

struct ArtifactPreview: View {
    @ObservedObject var store: ControllerStore
    let artifact: ArtifactRecord
    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.isDemo {
                    ContentUnavailableView("Artifact preview", systemImage: "square.stack.3d.up", description: Text("This is a design preview. Pair a Mac to open its shared artifacts."))
                } else if let request = store.artifactRequest(artifact), artifact.kind == "web" {
                    ArtifactWebView(request: request)
                } else if let localURL { QuickPreview(url: localURL) }
                else if let error { ContentUnavailableView("Couldn’t open artifact", systemImage: "wifi.exclamationmark", description: Text(error)) }
                else { ProgressView("Opening artifact…") }
            }
            .navigationTitle(artifact.title).navigationBarTitleDisplayMode(.inline)
            // A failure while this sheet is up would otherwise be reported behind it, unseen.
            .alert("Controller update", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) { ControllerSound.shared.keyClick(); store.lastError = nil }
            } message: { Text(store.lastError ?? "") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { ControllerSound.shared.keyClick(); dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { ControllerSound.shared.keyClick(); Task { await store.openArtifact(artifact) } } label: { Image(systemName: "desktopcomputer") }.accessibilityLabel("Open on Mac") }
            }
            .task {
                guard !store.isDemo else { return }
                guard let request = store.artifactRequest(artifact) else { error = "This artifact’s link is unavailable. Refresh the connection to its Mac and try again."; return }
                guard artifact.kind != "web" else { return }
                do {
                    let loader = URLSession(configuration: .ephemeral, delegate: ArtifactDownloadGuard(), delegateQueue: nil)
                    defer { loader.invalidateAndCancel() }
                    let (data, response) = try await loader.data(for: request)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
                    guard data.count <= 25 * 1024 * 1024 else { error = "This preview is larger than 25 MB. Open it on the Mac."; return }
                    let ext = artifact.kind == "pdf" ? "pdf" : artifact.kind == "image" ? (artifact.mimeType == "image/jpeg" ? "jpg" : "png") : "txt"
                    guard store.artifactRequest(artifact) == request else { return }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    try data.write(to: url, options: [.atomic, .completeFileProtection]); localURL = url
                } catch { self.error = error.localizedDescription }
            }
            .onDisappear { if let localURL { try? FileManager.default.removeItem(at: localURL) } }
        }
    }
}

struct ArtifactWebView: UIViewRepresentable {
    let request: URLRequest
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.privateOrigin = request.value(forHTTPHeaderField: "Authorization") == nil ? nil : request.url
        web.load(request)
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        var privateOrigin: URL?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if let origin = privateOrigin, (url.host != origin.host || url.port != origin.port || url.scheme != origin.scheme) { decisionHandler(.cancel); return }
            let scheme = url.scheme?.lowercased()
            decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
        }
    }
}

final class ArtifactDownloadGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Export endpoints do not redirect; never forward a pairing credential to a web destination.
        completionHandler(nil)
    }
}

struct QuickPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let view = QLPreviewController(); view.dataSource = context.coordinator; return view }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
