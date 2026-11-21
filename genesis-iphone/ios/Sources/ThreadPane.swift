import SwiftUI

/// How the thread is drawn: on a light panel (full screen) or on the deck's dark display.
struct ThreadStyle {
    var text: Color, dim: Color
    var userFill: Color, userStroke: Color, agentFill: Color, agentStroke: Color
    var panel: Bool
    static func light(_ accent: Color) -> ThreadStyle {
        .init(text: GenesisPalette.text, dim: GenesisPalette.dim, userFill: accent.opacity(0.16), userStroke: accent.opacity(0.25),
              agentFill: Color.white.opacity(0.7), agentStroke: GenesisPalette.hairline, panel: true)
    }
    static func dark(_ accent: Color, text: Color, dim: Color) -> ThreadStyle {
        .init(text: text, dim: dim, userFill: accent.opacity(0.30), userStroke: accent.opacity(0.45),
              agentFill: Color.white.opacity(0.08), agentStroke: Color.white.opacity(0.10), panel: false)
    }
}

/// The open chat's conversation, read-only. The text lives in the store's memory
/// only while a pane is on screen.
struct ThreadPane: View {
    @ObservedObject var store: ControllerStore
    let agentName: String
    let accent: Color
    var style: ThreadStyle? = nil
    @State private var pinned = true
    @State private var owner = UUID()
    private var look: ThreadStyle { style ?? .light(accent) }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        VStack(spacing: 0) {
            header
            if look.panel { Divider().opacity(0.5) }
            content
        }
        .modifier(PanelIf(on: look.panel))
        .onAppear { store.setThreadVisible(true, owner: owner) }
        .onDisappear { store.setThreadVisible(false, owner: owner) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.pane")
    }

    private var header: some View {
        HStack(spacing: 4) {
            if look.panel {
                Image(systemName: "text.bubble").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                Text("Thread").font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
            } else {
                Text("THREAD").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.6).foregroundStyle(accent)
            }
            Spacer(minLength: 0)
            Button { ControllerSound.shared.keyClick(); Task { await store.refreshThread(userInitiated: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).frame(width: 44, height: 44)
            }
            .disabled(store.selectedChat == nil)
            .accessibilityLabel("Refresh thread").accessibilityIdentifier("thread.refresh")
        }
        .foregroundStyle(look.dim)
        .padding(.leading, look.panel ? 12 : 0).padding(.trailing, 2)
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
            .font(.system(size: isPad ? 14 : 13, weight: .medium)).foregroundStyle(look.dim)
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
                            .font(.caption).foregroundStyle(look.dim).padding(.vertical, 4)
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
                .foregroundStyle(look.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(mine ? look.userFill : look.agentFill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(mine ? look.userStroke : look.agentStroke, lineWidth: 1))
            if !mine { Spacer(minLength: 36) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mine ? "You" : agentName): \(turn.text)")
        .accessibilityIdentifier("thread.message.\(index)")
    }
}

private struct PanelIf: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.genesisPanel(radius: 16) } else { content }
    }
}
