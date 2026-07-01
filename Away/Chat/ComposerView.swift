import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let isSteering: Bool
    let statusLabel: String?
    let onSend: () -> Void

    private var shouldShowSteeringLabel: Bool {
        ComposerStatusPolicy.shouldShowSteeringLabel(isSteering: isSteering, draftText: text)
    }

    var body: some View {
        VStack(spacing: 6) {
            if shouldShowSteeringLabel || statusLabel != nil {
                HStack(spacing: 6) {
                    Image(systemName: statusLabel == nil ? "arrow.triangle.2.circlepath" : "clock")
                    Text(statusLabel ?? "Steering active run")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Goose", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(isSteering ? "Steer active run" : "Send message")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }
}

enum ComposerStatusPolicy {
    static func shouldShowSteeringLabel(isSteering: Bool, draftText: String) -> Bool {
        isSteering && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
