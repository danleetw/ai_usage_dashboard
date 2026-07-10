import AppKit

private final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    var window: WidgetWindow?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ServerLauncher.isDashboardReachable(baseUrl: options.baseUrl) {
            if !ServerLauncher.ensureNodeAndStartServer(baseUrl: options.baseUrl) {
                NSApp.terminate(nil)
                return
            }
        }

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = options.width > 0 ? CGFloat(options.width) : (options.mini ? screen.width / 5 : 380)
        let height: CGFloat = options.height > 0 ? CGFloat(options.height) : (options.mini ? 28 : 480)
        let x = screen.maxX - width - CGFloat(options.margin)
        // Top-right corner: macOS y grows upward, so "near the top" means near visibleFrame.maxY.
        let y = screen.maxY - height - CGFloat(options.margin)

        var urlString = options.baseUrl + "/?widget=1"
        if options.mini {
            urlString += "&mini=1"
            if !options.provider.isEmpty {
                let encoded = options.provider.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? options.provider
                urlString += "&provider=\(encoded)"
            }
        }

        let win = WidgetWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            mini: options.mini,
            urlString: urlString
        )
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// Shared entry point for both the full-card (AiDashWidgetMac) and mini-bar (AiDashWidgetMiniMac)
// executable targets -- they're otherwise identical, differing only in whether --mini is forced.
public enum AppRunner {
    public static func run(forceMini: Bool) {
        var options = LaunchOptions.parse(CommandLine.arguments)
        if forceMini { options.mini = true }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // No title bar / close button by design (matches "Alt+F4 to close" on Windows) -- still
        // wire up Cmd+Q since a code-only app has no menu bar otherwise, and macOS won't quit
        // just because the (borderless) window closes without a bit of extra hand-holding.
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        app.mainMenu = mainMenu

        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        app.run()
    }
}
