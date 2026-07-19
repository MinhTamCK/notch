import AppKit
import DynamicNotchKit
import SwiftUI

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Everything lives in the notch panel (gear icon → settings); no menu bar item.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()
    private var notch: DynamicNotch<ExpandedView, CompactLeadingView, CompactTrailingView>?
    private var autoExpanded = false
    private var isExpanded = false
    private var clickMonitor: Any?
    private var compactDebounce: Task<Void, Never>?

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
            self?.compactDebounce?.cancel()
            self?.autoExpanded = false
            self?.setNotch(expanded: true)
        }
        model.requestCompact = { [weak self] in
            self?.compactDebounce?.cancel()
            self?.autoExpanded = false
            self?.setNotch(expanded: false)
        }
        model.onAllResolved = { [weak self] in
            guard let self, self.isExpanded else { return }
            // Collapse shortly after the final decision, so the card animates out first.
            self.compactDebounce?.cancel()
            self.compactDebounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled, let self, self.isExpanded else { return }
                self.autoExpanded = false
                self.setNotch(expanded: false)
            }
        }
        model.onAttention = { [weak self] hasAttention in
            guard let self else { return }
            if hasAttention {
                self.compactDebounce?.cancel()
                self.autoExpanded = true
                self.setNotch(expanded: true)
            } else if self.autoExpanded {
                // Debounce auto-collapse so back-to-back approvals don't flicker the panel.
                self.compactDebounce?.cancel()
                self.compactDebounce = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled, let self, self.autoExpanded else { return }
                    self.autoExpanded = false
                    self.setNotch(expanded: false)
                }
            }
        }

        // Any click on the notch surface toggles it — not just the small controls.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleClick(event) ?? event
        }

        model.start()
        setNotch(expanded: false)
    }

    /// Returns nil to swallow the event when it toggled the notch.
    private func handleClick(_ event: NSEvent) -> NSEvent? {
        guard let panel = notch?.windowController?.window, event.window === panel else { return event }
        if !isExpanded {
            autoExpanded = false
            setNotch(expanded: true)
            return nil
        }
        // Expanded: a click on the black notch strip along the top collapses.
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        if let screen = panel.screen ?? NSScreen.screens.first,
           screen.frame.maxY - screenPoint.y <= 44 {
            autoExpanded = false
            setNotch(expanded: false)
            return nil
        }
        return event
    }

    private func setNotch(expanded: Bool) {
        guard let notch, let screen = NSScreen.screens.first else { return }
        isExpanded = expanded
        Task { @MainActor in
            if expanded {
                await notch.expand(on: screen)
            } else {
                await notch.compact(on: screen)
            }
        }
    }
}
