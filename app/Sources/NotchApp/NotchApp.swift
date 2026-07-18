import AppKit
import DynamicNotchKit
import SwiftUI

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Notch", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent(model: delegate.model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("\(model.connection.rawValue) — \(model.serverDescription)")
        Text("\(model.workingCount) working · \(model.attentionCount) need you")
        Divider()
        Button("Show sessions") { model.requestExpand?() }
        Button("Reconnect") { model.connect() }
        Divider()
        Button("Quit Notch") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()
    private var notch: (any DynamicNotchControllable)?
    private var autoExpanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = self.model
        notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow]) {
            ExpandedView(model: model)
        } compactLeading: {
            CompactLeadingView(model: model)
        } compactTrailing: {
            CompactTrailingView(model: model)
        }

        model.requestExpand = { [weak self] in
            self?.autoExpanded = false
            self?.setNotch(expanded: true)
        }
        model.requestCompact = { [weak self] in
            self?.autoExpanded = false
            self?.setNotch(expanded: false)
        }
        model.onAttention = { [weak self] hasAttention in
            guard let self else { return }
            if hasAttention {
                self.autoExpanded = true
                self.setNotch(expanded: true)
            } else if self.autoExpanded {
                self.autoExpanded = false
                self.setNotch(expanded: false)
            }
        }

        model.connect()
        setNotch(expanded: false)
    }

    private func setNotch(expanded: Bool) {
        guard let notch, let screen = NSScreen.screens.first else { return }
        Task { @MainActor in
            if expanded {
                await notch.expand(on: screen)
            } else {
                await notch.compact(on: screen)
            }
        }
    }
}
