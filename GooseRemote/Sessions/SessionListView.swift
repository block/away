import SwiftUI
import UIKit

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) {
                            Task { await model.connect() }
                        }
                    }

                    SessionControls(
                        isKeepaliveEnabled: Binding(
                            get: { model.demoBackgroundKeepaliveEnabled },
                            set: { newValue in
                                guard newValue != model.demoBackgroundKeepaliveEnabled else { return }
                                model.toggleDemoBackgroundKeepalive()
                            }
                        )
                    ) {
                        Task { await model.refreshSessions() }
                    }

                    sessionContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .background(SessionListBackground())
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable {
                await model.refreshSessions()
            }
            .navigationDestination(for: String.self) { sessionID in
                ChatView(sessionID: sessionID)
                    .toolbar(.visible, for: .navigationBar)
            }
            .onChange(of: path) { _, newPath in
                guard let sessionID = newPath.last else { return }
                model.prepareSessionForNavigation(sessionID)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Goose")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))

            ConnectionStatusStrip(state: model.connectionState, summary: summaryText)

            if model.demoBackgroundKeepaliveEnabled {
                Label("Demo keepalive is active", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var sessionContent: some View {
        if model.sessions.isEmpty {
            switch model.connectionState {
            case .connected:
                EmptySessionsView {
                    Task { await model.refreshSessions() }
                }
            case .connecting:
                LoadingSessionsView()
            case .disconnected, .failed:
                EmptyView()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 2)

                LazyVStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        Button {
                            model.prepareSessionForNavigation(session.id)
                            if path.isEmpty {
                                path.append(session.id)
                            }
                        } label: {
                            VStack(spacing: 0) {
                                SessionRowView(session: session)

                                if index < model.sessions.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .buttonStyle(SessionRowButtonStyle())
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
            }
        }
    }

    private var summaryText: String {
        switch model.connectionState {
        case .connected where model.sessions.count == 1:
            "1 existing session"
        case .connected:
            "\(model.sessions.count) existing sessions"
        case .connecting:
            "Connecting to Goose ACP"
        case .disconnected:
            "Disconnected from Goose ACP"
        case .failed:
            "Connection needs attention"
        }
    }
}

private struct SessionControls: View {
    @Binding var isKeepaliveEnabled: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("Refresh sessions")

            Toggle(isOn: $isKeepaliveEnabled) {
                Label("Keepalive", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .toggleStyle(.switch)
            .accessibilityHint("Keeps demo background listening scaffolding active.")
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
    }
}

private struct ConnectionStatusStrip: View {
    let state: AppModel.ConnectionState
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityLabel("Connection status: \(label)")
        .accessibilityValue(summary)
    }

    private var label: String {
        switch state {
        case .failed:
            "Error"
        default:
            state.label
        }
    }

    private var statusColor: Color {
        switch state {
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

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Unable to reach Goose")
                    .font(.subheadline.weight(.semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry connection")
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct SessionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Rectangle()
                    .fill(configuration.isPressed ? Color(uiColor: .secondarySystemFill) : .clear)
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct LoadingSessionsView: View {
    private let placeholders = [
        SessionSummary(id: "loading-1", title: "Reviewing transcript updates", subtitle: "Loading the latest Goose session activity", updatedAt: Date(), messageCount: 18),
        SessionSummary(id: "loading-2", title: "Planning iOS polish", subtitle: "Waiting for session metadata", updatedAt: Date().addingTimeInterval(-2_400), messageCount: 7),
        SessionSummary(id: "loading-3", title: "Investigating ACP transport", subtitle: "Resolving working directory", updatedAt: Date().addingTimeInterval(-7_200), messageCount: 3)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            VStack(spacing: 8) {
                ForEach(Array(placeholders.enumerated()), id: \.element.id) { index, session in
                    VStack(spacing: 0) {
                        SessionRowView(session: session)
                        if index < placeholders.count - 1 {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
    }
}

private struct EmptySessionsView: View {
    let refresh: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No sessions", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("No existing Goose sessions are available from the configured server.")
        } actions: {
            Button("Refresh", action: refresh)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct SessionListBackground: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
    }
}

#Preview("Sessions") {
    let model = AppModel()
    model.sessions = [
        SessionSummary(id: "one", title: "Investigate CI", subtitle: "Build failed in lint after the session replay reducer changed.", cwd: "/Users/tomb/Development/ios-register", updatedAt: Date(), providerID: "openrouter", modelID: "claude-opus-5", messageCount: 12, isWorking: true),
        SessionSummary(id: "two", title: "Prototype app", subtitle: "Added ACP transport and checked reconnect handling.", cwd: "/Users/tomb/Development/goose-ios-remote", updatedAt: Date().addingTimeInterval(-3_600), providerID: "openai", modelID: "gpt-5", messageCount: 4),
        SessionSummary(id: "three", title: "Docs sweep", subtitle: nil, cwd: "/tmp/research/goose", updatedAt: Date().addingTimeInterval(-86_400), messageCount: 0)
    ]
    model.connectionState = .connected
    return SessionListView()
        .environment(model)
}

#Preview("Connecting") {
    let model = AppModel()
    model.connectionState = .connecting
    return SessionListView()
        .environment(model)
}

#Preview("Empty") {
    let model = AppModel()
    model.connectionState = .connected
    return SessionListView()
        .environment(model)
}
