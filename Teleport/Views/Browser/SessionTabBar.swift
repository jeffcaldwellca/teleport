import SwiftUI
import TeleportKit

/// The strip of open sessions above the remote pane. Shown only when there
/// is more than one, so a single connection looks as it always has.
struct SessionTabBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(appState.sessions) { session in
                        SessionTab(
                            session: session,
                            title: appState.title(for: session),
                            isActive: session.id == appState.activeSessionID
                        )
                        .id(session.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sessions")
            }
            // Keep the active tab in view when it changes by keyboard or by
            // opening a new session off the end of the strip.
            .onChange(of: appState.activeSessionID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(.bar)
    }
}

private struct SessionTab: View {
    let session: RemoteSession
    let title: String
    let isActive: Bool

    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                appState.activate(session.id)
            } label: {
                HStack(spacing: 6) {
                    if session.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: session.connection.connectionProtocol.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    Text(title)
                        .font(.callout)
                        .fontWeight(isActive ? .medium : .regular)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(title) — \(session.connection.displaySubtitle)")
            .accessibilityLabel(session.isConnecting ? "Session \(title), connecting" : "Session \(title)")
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Button {
                Task { await appState.closeSession(session.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Always present so tabs don't change width on hover.
            .opacity(isActive || isHovered ? 1 : 0.35)
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                               : AnyShapeStyle(isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .onHover { isHovered = $0 }
    }
}
