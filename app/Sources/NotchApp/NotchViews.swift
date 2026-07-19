import AppKit
import ServiceManagement
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
        case .working: .cyan
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

// MARK: - Shared styling

private let cardBackground = Color.white.opacity(0.07)
private let panelSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    prominent ? Color.white
                        : destructive ? Color.red.opacity(0.85)
                        : Color.white.opacity(0.14)
                )
            )
            .foregroundStyle(prominent ? Color.black : Color.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Animated audio-visualizer bars, shown while agents are working.
struct EqualizerBars: View {
    var active: Bool
    var color: Color = .cyan

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * 2.6 + Double(i) * 0.9
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 2.5, height: active ? 4 + 8 * abs(sin(phase)) : 3)
                }
            }
            .frame(width: 18, height: 14)
        }
    }
}

// MARK: - Compact state

/// Per-agent badge: real app icon when bundled, glyph fallback in dev builds.
struct AgentBadge: View {
    let agent: String?
    var dimmed = false

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.image(for: agent) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                let style = Self.style(agent)
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(style.color.opacity(0.18))
                    Text(style.glyph)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(style.color)
                }
            }
        }
        .frame(width: 20, height: 20)
        .opacity(dimmed ? 0.5 : 1)
    }

    private static func image(for agent: String?) -> NSImage? {
        let name: String?
        switch agent {
        case "claude-code", "claude": name = "agent-claude"
        case "cursor": name = "agent-cursor"
        default: name = nil
        }
        guard let name else { return nil }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    static func style(_ agent: String?) -> (glyph: String, color: Color) {
        switch agent {
        case "claude-code", "claude":
            return ("✳", Color(red: 0.85, green: 0.47, blue: 0.34))
        case "cursor":
            return ("▮", Color(white: 0.92))
        default:
            return ("👾", .purple)
        }
    }
}

struct CompactLeadingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            EqualizerBars(active: model.workingCount > 0)
            Text(model.workingCount > 0 ? "\(model.workingCount)" : "idle")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(model.workingCount > 0 ? .white : .secondary)
        }
        // Expansion is handled by the app-wide click monitor covering the whole notch.
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
                        .symbolEffect(.pulse, options: .repeating, isActive: true)
                    Text("\(model.attentionCount)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            } else if model.connection != .connected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
            } else {
                Text("👾")
                    .font(.system(size: 11))
                    .opacity(0.85)
            }
        }
        .font(.caption)
    }
}

// MARK: - Expanded state

struct ExpandedView: View {
    @ObservedObject var model: AppModel
    @State private var showAll = false
    @State private var showSettings = false

    private var pending: [PermissionRequest] {
        model.pendingPermissions.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// While permissions are pending, focus on their sessions; the rest collapse
    /// behind a "Show all" link (like the reference UI).
    private var focusedSessions: [Session] {
        let all = model.visibleSessions
        guard !pending.isEmpty, !showAll else { return all }
        let focusKeys = Set(pending.map { "\($0.machine):\($0.sessionId)" })
        return all.filter { focusKeys.contains($0.key) }
    }

    private var machines: [(name: String, sessions: [Session])] {
        Dictionary(grouping: focusedSessions, by: \.machine)
            .map { (name: $0.key, sessions: $0.value) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if showSettings {
                SettingsSection(model: model)
            } else {
            if !pending.isEmpty {
                VStack(spacing: 8) {
                    ForEach(pending) { request in
                        PermissionCard(request: request, model: model)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
            }

            if model.visibleSessions.isEmpty {
                Text("No active sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(machines, id: \.name) { machine in
                            Text(machine.name.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(machine.sessions) { session in
                                SessionRow(session: session)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)

                let hidden = model.visibleSessions.count - focusedSessions.count
                if hidden > 0 {
                    Button("Show all \(model.visibleSessions.count) sessions") {
                        withAnimation(panelSpring) { showAll = true }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            }
        }
        .padding(14)
        .frame(width: 400)
        .contentShape(Rectangle())
        // Tap anywhere in the panel to collapse; buttons and links still win.
        .onTapGesture { model.requestCompact?() }
        .animation(panelSpring, value: model.pendingPermissions)
        .animation(panelSpring, value: model.sessions)
        .onChange(of: pending.isEmpty) { _, isEmpty in
            if isEmpty { showAll = false }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            EqualizerBars(active: model.workingCount > 0)
            Text("\(model.workingCount) working")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(model.visibleSessions.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                model.soundEnabled.toggle()
            } label: {
                Image(systemName: model.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(model.soundEnabled ? Color.secondary : Color.orange)
            }
            .buttonStyle(.plain)
            .help(model.soundEnabled ? "Mute alerts" : "Unmute alerts")
            Button {
                withAnimation(panelSpring) { showSettings.toggle() }
            } label: {
                Image(systemName: showSettings ? "xmark.circle.fill" : "gearshape.fill")
                    .font(.caption)
                    .foregroundStyle(showSettings ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(showSettings ? "Back to sessions" : "Settings")
            Circle()
                .fill(model.connection == .connected ? .green : .red)
                .frame(width: 6, height: 6)
        }
    }
}

// MARK: - Settings (gear icon in the header)

struct SettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var hooksInstalled = LocalSetup.isInstalled
    @State private var copied = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow(
                title: model.mode == .hosting ? "Server" : "Connection",
                subtitle: model.serverDescription
            ) {
                Text(model.mode == .hosting ? "hosting" : model.connection.rawValue)
                    .font(.caption2)
                    .foregroundStyle(model.connection == .connected ? .green : .red)
            }

            settingRow(
                title: "Claude Code on this Mac",
                subtitle: hooksInstalled ? "Hooks installed" : "Sessions on this Mac won't appear yet"
            ) {
                Button(hooksInstalled ? "Reinstall" : "Install") {
                    try? LocalSetup.install()
                    hooksInstalled = LocalSetup.isInstalled
                }
                .buttonStyle(PillButtonStyle(prominent: !hooksInstalled))
            }

            if model.mode == .hosting {
                settingRow(
                    title: "Add remote machine",
                    subtitle: "Paste the command in the remote shell"
                ) {
                    Button(copied ? "Copied ✓" : "Copy command") {
                        RemoteAdd.copyToClipboard(token: model.token, port: model.hostedPort)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                }
            } else {
                settingRow(title: "Reconnect", subtitle: "Re-read ~/.notch/env and retry") {
                    Button("Reconnect") { model.start() }
                        .buttonStyle(PillButtonStyle())
                }
            }

            if Bundle.main.bundlePath.hasSuffix(".app") {
                settingRow(title: "Launch at Login", subtitle: nil) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: launchAtLogin) { _, enable in
                            do {
                                if enable {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }

            HStack {
                Text("Notch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(PillButtonStyle(destructive: true))
            }
            .padding(.top, 2)
        }
    }

    private func settingRow(
        title: String,
        subtitle: String?,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBackground))
    }
}

// MARK: - Permission card

struct PermissionCard: View {
    let request: PermissionRequest
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentBadge(agent: request.agent)
                Text(request.projectName)
                    .font(.callout.weight(.semibold))
                Text("· \(request.machine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(request.isPlan ? "Plan" : request.toolName,
                      systemImage: request.isPlan ? "list.clipboard" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            detailView

            HStack {
                Button("Deny") { model.decide(request.id, decision: "deny") }
                    .buttonStyle(PillButtonStyle(destructive: true))
                Spacer()
                Button(request.isPlan ? "Approve Plan" : "Allow Once") {
                    model.decide(request.id, decision: "allow")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var detailView: some View {
        if let diff = request.editDiff {
            DiffView(file: request.filePath, removed: diff.removed, added: diff.added)
        } else if let content = request.writeContent {
            DiffView(file: request.filePath, removed: [], added: content)
        } else if request.isPlan, let plan = request.detail {
            ScrollView {
                Text(planText(plan))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.35)))
        } else if let detail = request.detail {
            Text(detail)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.35)))
        }
    }

    private func planText(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// Red/green diff preview like the reference app's Edit approval.
struct DiffView: View {
    let file: String?
    let removed: [String]
    let added: [String]

    private let maxLines = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.map { ($0 as NSString).lastPathComponent } ?? "")
                    .foregroundStyle(.secondary)
                Spacer()
                if !added.isEmpty {
                    Text("+\(added.count)").foregroundStyle(.green)
                }
                if !removed.isEmpty {
                    Text("−\(removed.count)").foregroundStyle(.red)
                }
            }
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.bottom, 3)

            ForEach(Array(removed.prefix(maxLines).enumerated()), id: \.offset) { _, line in
                diffLine("− \(line)", tint: .red)
            }
            if removed.count > maxLines {
                Text("… \(removed.count - maxLines) more")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(added.prefix(maxLines).enumerated()), id: \.offset) { _, line in
                diffLine("+ \(line)", tint: .green)
            }
            if added.count > maxLines {
                Text("… \(added.count - maxLines) more")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.35)))
    }

    private func diffLine(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(tint)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(tint.opacity(0.12))
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: Session

    private var subtitle: String? {
        if let message = session.lastMessage { return "You: \(message)" }
        return session.lastTool
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                AgentBadge(agent: session.agent, dimmed: session.state != .working)
                if session.state != .working {
                    Image(systemName: session.state.icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(session.state.color)
                        .offset(x: 8, y: 8)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.projectName)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                    if session.state == .working {
                        EqualizerBars(active: true)
                            .scaleEffect(0.7)
                    } else {
                        Text(session.state.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(session.state.color)
                    }
                    Spacer()
                    Text(session.updatedDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBackground))
    }
}
