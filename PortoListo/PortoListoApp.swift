import SwiftUI
import Combine

@main
struct PortoListoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = PortMonitor()

    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateBarButton(activeCount: 0, isRefreshing: false)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(monitor: monitor))

        // Update menu bar icon when statuses or refreshing state changes
        monitor.$statuses.combineLatest(monitor.$isRefreshing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses, isRefreshing in
                let active = statuses.filter { $0.isActive }.count
                self?.updateBarButton(activeCount: active, isRefreshing: isRefreshing)
            }
            .store(in: &cancellables)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func updateBarButton(activeCount: Int, isRefreshing: Bool) {
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let icon = (!isRefreshing && activeCount > 0)
            ? "network.badge.shield.half.filled"
            : "network"
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: "porto-listo")?
            .withSymbolConfiguration(cfg)
        button.title = activeCount > 0 ? " \(activeCount)" : ""
        button.imagePosition = .imageLeft
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            monitor.isPopoverOpen = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.isPopoverOpen = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }
}
