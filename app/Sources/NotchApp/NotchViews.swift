import SwiftUI

extension SessionState {
    var icon: String {
        switch self {
        case .working: "hammer.fill"
        case .needsPermission: "hand.raised.fill"
        case .needsAttention: "bell.fill"
        case .done: "checkmark.circle.fill"
        case .ended: "xmark.circle"
        case .stale: "moon.zzz.fill"
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .needsPermission: .orange
        case .needsAttention: .yellow
        case .done: .green
        case .ended, .stale: .gray
        }
    }

    var label: String {
        switch self {
        case .working: "working"
        case .needsPermission: "needs permission"
        case .needsAttention: "needs attention"
        case .done: "done"
        case .ended: "ended"
        case .stale: "stale"
        }
    }
}

struct CompactLeadingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hammer.fill")
                .foregroundStyle(.blue)
            Text("\(model.workingCount)")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .contentShape(Rectangle())
        .onTapGesture { model.requestExpand?() }
    }
}

struct CompactTrailingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.attentionCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.orange)
                    Text("\(model.attentionCount)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            } else if model.connection != .connected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .contentShape(Rectangle())
        .onTapGesture { model.requestExpand?() }
    }
}

struct ExpandedView: View {
    @ObservedObject var model: AppModel

    private var machines: [(name: String, sessions: [Session])] {
        Dictionary(grouping: model.visibleSessions, by: \.machine)
            .map { (name: $0.key, sessions: $0.value) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connection == .connected ? .green : .red)
                    .frame(width: 7, height: 7)
                Text("Notch")
                    .font(.headline)
                Text(model.connection == .connected ? model.serverDescription : model.connection.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.requestCompact?()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            let pending = model.pendingPermissions.values.sorted { $0.createdAt < $1.createdAt }
            if !pending.isEmpty {
                VStack(spacing: 8) {
                    ForEach(pending) { request in
                        PermissionCard(request: request, model: model)
                    }
                }
                Divider()
            }

            if model.visibleSessions.isEmpty {
                Text("No active sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(machines, id: \.name) { machine in
                            Text(machine.name)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(machine.sessions) { session in
                                SessionRow(session: session)
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: request.isPlan ? "list.clipboard.fill" : "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("\(request.machine) · \(request.projectName)")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
                Text(request.isPlan ? "Plan" : request.toolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let detail = request.detail {
                if request.isPlan {
                    ScrollView {
                        Text(planText(detail))
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
                } else {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
                }
            }

            HStack {
                Button("Deny") { model.decide(request.id, decision: "deny") }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Spacer()
                Button(request.isPlan ? "Approve plan" : "Approve") {
                    model.decide(request.id, decision: "allow")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
    }

    private func planText(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

struct SessionRow: View {
    let session: Session

    private var subtitle: String {
        if session.state.needsUser {
            return session.lastMessage ?? session.lastTool ?? session.state.label
        }
        return session.lastTool ?? session.lastMessage ?? session.state.label
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.state.icon)
                .foregroundStyle(session.state.color)
                .font(.callout)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(session.projectName)
                        .font(.system(.callout, design: .rounded))
                        .fontWeight(.medium)
                    Spacer()
                    Text(session.updatedDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
