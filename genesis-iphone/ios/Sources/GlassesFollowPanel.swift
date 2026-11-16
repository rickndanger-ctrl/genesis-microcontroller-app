import SwiftUI

struct GlassesFollowPanel: View {
    @ObservedObject var store: ControllerStore
    @ObservedObject var follow: GlassesFollowController
    @State private var confirmTakeover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { follow.enabled }, set: { on in
                if on { store.enableGlassesFollow() } else { follow.stop() }
            })) {
                Label("Follow this controller", systemImage: "eyeglasses")
                    .font(.headline)
            }
            .disabled(store.isDemo || store.selectedProvider == .muse || !store.isPaired)
            .accessibilityHint("Show this controller’s confirmed conversation and draft on your G2 glasses.")

            Label(follow.message, systemImage: follow.acknowledged ? "checkmark.circle.fill" : follow.unsupported ? "arrow.down.app" : "info.circle")
                .font(.caption)

                .foregroundStyle(follow.acknowledged ? Color.green : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let owner = follow.otherOwner, !follow.enabled {
                Button("Take over from \(owner)") { confirmTakeover = true }
                    .buttonStyle(.bordered)
            }

            if follow.enabled {
                HStack {
                    Label("This \(follow.sourceName) controls the display", systemImage: "dot.radiowaves.left.and.right")
                    Spacer(minLength: 4)
                    if follow.connecting { ProgressView().controlSize(.small) }
                }
                .font(.caption)

                Toggle("Keep reading when \(follow.sourceName) locks", isOn: Binding(
                    get: { follow.keepReadingPreference }, set: { follow.setKeepReading($0) }))
                    .disabled(!follow.canSetKeepReading)
                    .accessibilityIdentifier("glasses.keepReading")
                Text(follow.supportsKeepReading
                     ? "The Mac keeps this conversation readable for up to one hour. Your microphone stops and your unsent draft stays private on this device."
                     : "Update Genesis on the selected Mac to enable reading after lock.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !follow.readingMessage.isEmpty {
                    Label(follow.readingMessage, systemImage: follow.readingChangePending ? "hourglass" : follow.readingArmed ? "checkmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !follow.hasChat {
                    Text("Open an assigned chat to show it on the glasses.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack { viewButtons }
                    VStack(alignment: .leading) { viewButtons }
                }

                Text("Conversation starts at the newest text. The right arrow shows older conversation text. Choose Draft to page through your current draft. Both stay visible on your glasses.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("glasses.pageHelp")

                HStack(spacing: 12) {
                    Button { follow.page(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 28, minHeight: 28) }
                        .accessibilityIdentifier("glasses.previous")
                        .disabled(!follow.controlsAvailable || follow.desired.page == 0 || follow.desired.view == .home)
                        .accessibilityLabel("Previous glasses page")
                    Text(follow.pageLabel).font(.caption.monospacedDigit()).frame(maxWidth: .infinity)
                    Button { follow.page(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 28, minHeight: 28) }
                        .accessibilityIdentifier("glasses.next")
                        .disabled(!follow.canGoNext)
                        .accessibilityLabel("Next glasses page")
                }
                .buttonStyle(.bordered)

                HStack {
                    Button { follow.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .accessibilityIdentifier("glasses.refresh")
                        .buttonStyle(.bordered)
                        .disabled(!follow.controlsAvailable)
                    Spacer(minLength: 8)
                    Button { Task { await store.sendDraft() } } label: { Label("Send draft", systemImage: "arrow.up.circle.fill") }
                        .accessibilityIdentifier("glasses.send")
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canSend)
                        .accessibilityHint("Send the reviewed draft to the selected Mac chat once, using the normal delivery receipt.")
                }

                Text("Hold the microphone on the controller, release to review, then Send draft. Nothing sends from the glasses display.")
                    .font(.caption).foregroundStyle(.secondary)
                if follow.draftIsExcerpt {
                    Text("Glasses show the first 16,000 characters. Your complete draft stays here for review and Send.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("This screen stays awake while Follow is on. Enable background relay in the Even Beta on your connected iPhone for reading while it is locked. Without Keep reading, leaving Genesis pauses Follow.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("G2 · Use your iPad with Even open on iPhone, or enable background relay in the Even Beta for same-iPhone control.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 24))
        .confirmationDialog("Switch which device controls the glasses?", isPresented: $confirmTakeover, titleVisibility: .visible) {
            Button("Follow this \(follow.sourceName)") { store.enableGlassesFollow(takeover: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The other controller will stop publishing to the glasses. Its chat drafts are kept on that device.")
        }
    }

    @ViewBuilder private var viewButtons: some View {
        Button { follow.show(.reply) } label: { Label("Conversation", systemImage: "text.bubble") }
            .accessibilityIdentifier("glasses.reply")
            .disabled(!follow.controlsAvailable || !follow.hasChat)
            .buttonStyle(.bordered)
            .tint(follow.desired.view == .reply ? .blue : .secondary)
        Button { follow.show(.draft) } label: { Label("Draft", systemImage: "square.and.pencil") }
            .accessibilityIdentifier("glasses.draft")
            .disabled(!follow.controlsAvailable || !follow.hasChat)
            .buttonStyle(.bordered)
            .tint(follow.desired.view == .draft ? .blue : .secondary)
        Button { follow.show(.home) } label: { Label("Home", systemImage: "square.grid.2x2") }
            .accessibilityIdentifier("glasses.home")
            .disabled(!follow.controlsAvailable)
            .buttonStyle(.bordered)
            .tint(follow.desired.view == .home ? .blue : .secondary)
    }
}
