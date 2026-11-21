import SwiftUI

/// The open chat's conversation, read-only, for the side panel of the iPad's full-screen size.
/// The text lives in the store's memory only while this pane is on screen.
struct ThreadPane: View {
    @ObservedObject var store: ControllerStore
    let agentName: String
    let accent: Color
    @State private var pinned = true

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .genesisPanel(radius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.pane")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            Text("Thread").font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
            Spacer(minLength: 0)
            Button { ControllerSound.shared.keyClick(); Task { await store.refreshThread(userInitiated: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).frame(width: 40, height: 40)
            }
            .disabled(store.selectedChat == nil)
            .accessibilityLabel("Refresh thread").accessibilityIdentifier("thread.refresh")
        }
        .foregroundStyle(GenesisPalette.dim)
        .padding(.leading, 12).padding(.trailing, 2)
    }

    @ViewBuilder private var content: some View {
        if store.selectedChat == nil {
            notice("Choose a chat to see its thread")
        } else {
            switch store.thread {
            case .idle: Color.clear
            case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsUpdate: notice("Update the Mac companion to see threads here")
            case let .unavailable(message), let .failed(message): notice(message)
            case let .loaded(turns, truncated):
                if turns.isEmpty { notice("No messages in this chat yet") } else { messages(turns, truncated: truncated) }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: isPad ? 14 : 13, weight: .medium)).foregroundStyle(GenesisPalette.dim)
            .multilineTextAlignment(.center).padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("thread.notice")
    }

    private func messages(_ turns: [ThreadTurn], truncated: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if truncated {
                        Text("Earlier messages are on your Mac")
                            .font(.caption).foregroundStyle(GenesisPalette.dim).padding(.vertical, 4)
                            .accessibilityIdentifier("thread.truncated")
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in bubble(turn, index: index) }
                    Color.clear.frame(height: 1).id("thread.end")
                        .onAppear { pinned = true }.onDisappear { pinned = false }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: turns) { if pinned { proxy.scrollTo("thread.end", anchor: .bottom) } }
        }
        // A new chat starts at its newest message.
        .id(store.selectedChat?.id)
    }

    private func bubble(_ turn: ThreadTurn, index: Int) -> some View {
        let mine = turn.isUser
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 36) }
            Text(turn.text)
                .font(.system(size: isPad ? 15 : 14))
                .foregroundStyle(GenesisPalette.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(mine ? accent.opacity(0.16) : Color.white.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(mine ? accent.opacity(0.25) : GenesisPalette.hairline, lineWidth: 1))
            if !mine { Spacer(minLength: 36) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mine ? "You" : agentName): \(turn.text)")
        .accessibilityIdentifier("thread.message.\(index)")
    }
}
