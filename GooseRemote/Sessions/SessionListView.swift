import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $path) {
            List {
                Section {
                    connectionStatus
                }

                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("No existing Goose sessions are available from the configured server.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    Section("Recent") {
                        ForEach(model.sessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRowView(session: session)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Goose")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh sessions")

                    Button {
                        model.toggleDemoBackgroundKeepalive()
                    } label: {
                        Image(systemName: model.demoBackgroundKeepaliveEnabled ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right.circle")
                    }
                    .accessibilityLabel("Toggle demo background keepalive")
                }
            }
            .refreshable {
                await model.refreshSessions()
            }
            .navigationDestination(for: String.self) { sessionID in
                ChatView(sessionID: sessionID)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(model.connectionState.label)
                .font(.subheadline)
            Spacer()
            if model.demoBackgroundKeepaliveEnabled {
                Text("Demo BG")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected:
            .green
        case .connecting:
            .orange
        case .disconnected:
            .secondary
        case .failed:
            .red
        }
    }
}

#Preview {
    let model = AppModel()
    model.sessions = [
        SessionSummary(id: "one", title: "Investigate CI", subtitle: "Build failed in lint", updatedAt: Date(), messageCount: 12),
        SessionSummary(id: "two", title: "Prototype app", subtitle: "Added ACP transport", updatedAt: Date().addingTimeInterval(-3600), messageCount: 4)
    ]
    return SessionListView()
        .environment(model)
}
