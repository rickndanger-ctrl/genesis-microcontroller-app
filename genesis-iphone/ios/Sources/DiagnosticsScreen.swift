import SwiftUI

/// "Check this Mac": what the companion on the selected Mac can and cannot
/// find in the apps it controls, and what it has done lately. Read-only.
struct DiagnosticsScreen: View {
    @ObservedObject var store: ControllerStore
    @State private var report: SelfCheckReport?
    @State private var activity: ActivityReport?
    @State private var checking = false
    @State private var failure: String?

    private var macName: String { store.selectedHost?.name ?? "this Mac" }

    var body: some View {
        List {
            Section {
                Button {
                    ControllerSound.shared.keyClick()
                    Task { await runCheck() }
                } label: {
                    Label(checking ? "Checking…" : "Run check", systemImage: "stethoscope")
                }
                .disabled(checking)
                .accessibilityIdentifier("diagnostics.run")
                Text("Looks for each control this app relies on in Claude, Muse and Codex on \(macName). Nothing is sent or changed, except that Muse’s chat list is shown so its chats can be counted.")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                }
                if let report {
                    Text(report.summary).font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("diagnostics.summary")
                    Text("Companion \(report.companionVersion) · checked \(report.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let report {
                ForEach(report.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(item.ok ? Color.green : Color.orange)
                                    .accessibilityLabel(item.ok ? "Found" : "Needs attention")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            Section("Recent activity") {
                Text("What each command was and how it ended. Message text is never recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                if let entries = activity?.newestFirst, !entries.isEmpty {
                    ForEach(entries.prefix(40)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("\(entry.provider.capitalized) · \(entry.action)").font(.subheadline.weight(.medium))
                                Spacer(minLength: 4)
                                Text(entry.status).font(.caption.weight(.semibold))
                                    .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
                            }
                            Text(entry.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text(entry.time.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text(activity == nil ? "Not loaded yet." : "No commands yet.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Check \(macName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadActivity() }
    }

    private func runCheck() async {
        checking = true; failure = nil
        defer { checking = false }
        do { report = try await store.selfCheck() }
        catch { failure = "The check could not run. \(error.localizedDescription)" }
        await loadActivity()
    }

    private func loadActivity() async {
        if let loaded = try? await store.recentActivity() { activity = loaded }
    }
}
