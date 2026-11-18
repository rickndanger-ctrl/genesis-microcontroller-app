import SwiftUI
import UIKit

/// The first thing an unpaired controller shows: how to get the Mac app, and
/// one tap to scan its code. Pairing finishes here, with a plain fix when the
/// phone can't reach the Mac.
struct ConnectGuide: View {
    @ObservedObject var store: ControllerStore
    /// Opens the sample controller instead, for someone without a Mac yet.
    var startDemo: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var pairing = false
    @State private var problem: String?
    @State private var offerSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your phone becomes a control deck for Claude, Codex and Muse on your Mac. It takes about a minute.")
                        .font(.body).foregroundStyle(.secondary)
                        .accessibilityIdentifier("guide.intro")

                    if let startDemo {
                        // First, so App Review and anyone without a Mac sees it without scrolling.
                        Button { ControllerSound.shared.keyClick(); dismiss(); startDemo() } label: {
                            Label("No Mac nearby? Try the demo", systemImage: "play.circle")
                        }
                        .accessibilityIdentifier("guide.tryDemo")
                        .accessibilityHint("A sample controller. Nothing is sent anywhere.")
                    }

                    step(1, "Get the free Mac app") {
                        Text("On your Mac, download Agent Micro Controller and open it. It walks you through the rest there.")
                        HStack(spacing: 10) {
                            ShareLink(item: ConnectionHelp.macAppPage, subject: Text("Agent Micro Controller for Mac"),
                                      message: Text("Download the Mac app for Agent Micro Controller")) {
                                Label("Send link", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("guide.shareMacLink")
                            Link(destination: ConnectionHelp.macAppPage) { Text("Open page") }
                                .buttonStyle(.bordered)
                        }
                        Text("AirDrop or Messages gets the link onto your Mac in one tap.").font(.caption).foregroundStyle(.secondary)
                    }

                    step(2, "Scan the code it shows") {
                        Text("Its setup window ends with a code. Scan it here, or point the iPhone Camera app at it. Your phone needs to be on the same Wi-Fi as the Mac.")
                        Button { ControllerSound.shared.keyClick(); scanning = true } label: {
                            Label(pairing ? "Connecting…" : "Scan the code", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(pairing)
                        .accessibilityIdentifier("guide.scan")
                        Text("When iPhone asks to find devices on your local network, tap Allow. That’s how it reaches your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let problem {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            if offerSettings {
                                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(14).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }

                }
                .padding(20)
            }
            .navigationTitle("Connect your Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { ControllerSound.shared.keyClick(); dismiss() }.accessibilityIdentifier("guide.close") } }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner { code in scanning = false; pair(code) }
                        .navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { ControllerSound.shared.keyClick(); scanning = false } } }
                }
            }
            // Pairing from the Camera app lands in the store; close once it worked.
            .onChange(of: store.hosts.count) { _, count in if count > 0 { dismiss() } }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func pair(_ code: String) {
        guard let url = URL(string: code) else { problem = RemoteError.invalidPairing.localizedDescription; return }
        pairing = true; problem = nil; offerSettings = false
        Task {
            defer { pairing = false }
            do { try await store.pair(url) }
            catch {
                problem = ConnectionHelp.describe(error, mac: nil)
                offerSettings = ConnectionHelp.problem(error).map(ConnectionHelp.fixedInSettings) ?? false
            }
        }
    }
}
