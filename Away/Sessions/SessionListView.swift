import SwiftUI
import UIKit

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header

                    if SessionListPresentation.shouldShowFailureView(connectionState: model.connectionState) {
                        ConnectionFailureView(message: model.errorMessage) {
                            Task { await model.connect() }
                        }
                    }

                    sessionContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 0)

                HeaderControls(
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
            }

            if shouldShowConnectionLine {
                ConnectionLine(state: model.connectionState, summary: summaryText)
            }
        }
    }

    private var shouldShowConnectionLine: Bool {
        SessionListPresentation.shouldShowConnectionLine(
            connectionState: model.connectionState,
            isKeepaliveEnabled: model.demoBackgroundKeepaliveEnabled
        )
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
            LazyVStack(spacing: 0) {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    Button {
                        guard path.isEmpty else { return }
                        model.prepareSessionForNavigation(session.id)
                        path.append(session.id)
                    } label: {
                        VStack(spacing: 0) {
                            SessionRowView(session: session)

                            if index < model.sessions.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .buttonStyle(SessionRowButtonStyle())
                }
            }
        }
    }

    private var summaryText: String {
        switch model.connectionState {
        case .connected where model.sessions.count == 1:
            "1 session"
        case .connected:
            "\(model.sessions.count) sessions"
        case .connecting:
            "Connecting"
        case .disconnected:
            "Disconnected"
        case .failed:
            "Connection failed"
        }
    }
}

enum SessionListPresentation {
    static func shouldShowConnectionLine(
        connectionState: AppModel.ConnectionState,
        isKeepaliveEnabled: Bool
    ) -> Bool {
        switch connectionState {
        case .connected:
            isKeepaliveEnabled
        case .connecting, .disconnected:
            true
        case .failed:
            false
        }
    }

    static func shouldShowFailureView(connectionState: AppModel.ConnectionState) -> Bool {
        if case .failed = connectionState {
            return true
        }
        return false
    }
}

private struct HeaderControls: View {
    @Binding var isKeepaliveEnabled: Bool
    let refresh: () -> Void

    var body: some View {
        Menu {
            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Toggle(isOn: $isKeepaliveEnabled) {
                Label("Demo keepalive", systemImage: "antenna.radiowaves.left.and.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 36, height: 36)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Session list options")
    }
}

private struct ConnectionLine: View {
    let state: AppModel.ConnectionState
    let summary: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if state == .connected {
                Text("Keepalive")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel("Connection status: \(summary)")
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

private struct ConnectionFailureView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn’t connect")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message ?? "Away could not reach the configured ACP target.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry connection")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
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
        SessionSummary(id: "loading-1", title: "Acronym Guide Summary", updatedAt: Date().addingTimeInterval(-82_800)),
        SessionSummary(id: "loading-2", title: "Test", updatedAt: Date().addingTimeInterval(-86_400)),
        SessionSummary(id: "loading-3", title: "Day query instructions", updatedAt: Date().addingTimeInterval(-86_400))
    ]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(placeholders.enumerated()), id: \.element.id) { index, session in
                SessionRowView(session: session)
                if index < placeholders.count - 1 {
                    Divider()
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private struct EmptySessionsView: View {
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No sessions")
                .font(.headline.weight(.semibold))

            Text("No existing Goose sessions are available from the configured server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Refresh", action: refresh)
                .buttonStyle(.borderless)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 32)
    }
}

private struct SessionListBackground: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}

#Preview("Sessions") {
    let model = AppModel()
    model.sessions = [
        SessionSummary(id: "one", title: "Acronym Guide Summary", updatedAt: Date().addingTimeInterval(-82_800), messageCount: 12),
        SessionSummary(id: "two", title: "Test", updatedAt: Date().addingTimeInterval(-86_400), messageCount: 4),
        SessionSummary(id: "three", title: "Day query instructions", updatedAt: Date().addingTimeInterval(-86_400), messageCount: 0),
        SessionSummary(id: "four", title: "Test session", updatedAt: Date().addingTimeInterval(-86_400), messageCount: 0)
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
