import AppKit
import WebKit

// macOS port of the WPF WidgetWindow class (see the Windows AiDashWidget project). Same
// contract: borderless, transparent, always-on-top window hosting a WKWebView pointed at
// index.html's widget mode, draggable by clicking non-interactive content, self-sizing to fit
// real rendered content once data loads.
public final class WidgetWindow: NSWindow, WKScriptMessageHandler, WKNavigationDelegate {
    private let mini: Bool
    private var webView: WKWebView!
    private let borderPad: CGFloat
    // The x/width the window should keep pinned at through the self-calibration resize below
    // (only height is meant to change) -- captured once at construction time.
    private let pinnedX: CGFloat
    private let pinnedWidth: CGFloat

    public init(contentRect: NSRect, mini: Bool, urlString: String) {
        self.mini = mini
        self.borderPad = mini ? 3 : 16
        self.pinnedX = contentRect.origin.x
        self.pinnedWidth = contentRect.width

        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "dragHandler")

        let wv = WKWebView(frame: NSRect(origin: .zero, size: contentRect.size), configuration: config)
        // Undocumented-but-long-stable KVC trick to stop WKWebView painting its own opaque
        // background, on top of the modern documented API below -- keeping both covers older
        // deployment targets where underPageBackgroundColor isn't available.
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = .clear
        }
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        self.webView = wv

        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.autoresizingMask = [.width, .height]
        container.addSubview(wv)
        self.contentView = container

        if let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
    }

    // The page (index.html, widget mode) posts a "drag" message via
    // window.webkit.messageHandlers.dragHandler when the user presses the left button on any
    // non-interactive area -- WKWebView swallows mouse input over its own bounds just like
    // WebView2 does on Windows, so the page has to initiate the drag itself.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dragHandler", (message.body as? String) == "drag" else { return }
        performManualDrag()
    }

    // AppKit's usual one-liner for this (NSWindow.performDrag(with:)) needs the actual mouseDown
    // NSEvent, which isn't available here -- the JS message arrives asynchronously, after
    // WKWebView has already consumed the real mouseDown. Since the mouse button is still
    // physically held down when this fires (JS posts the message from its own mousedown
    // handler), pumping the event queue directly for the drag/up events and repositioning the
    // window by hand works just as well.
    private func performManualDrag() {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = self.frame.origin
        var tracking = true
        while tracking {
            guard let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            switch event.type {
            case .leftMouseDragged:
                let current = NSEvent.mouseLocation
                let dx = current.x - startMouse.x
                let dy = current.y - startMouse.y
                self.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }
    }

    // The default window height is just a placeholder -- real content height varies with font
    // rendering / provider data. Once the page has actually loaded real data, measure the target
    // element (one full provider card, or the single mini bar line) and resize the window to fit
    // it exactly. Unlike the Windows/WPF version, no DPI self-calibration dance is needed here --
    // WKWebView's CSS pixels already map 1:1 onto NSWindow points regardless of Retina backing
    // scale, so the measured value can be applied directly.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let measureScript = mini
            ? "(function(){var el=document.getElementById('miniLine');return el?Math.ceil(el.getBoundingClientRect().height):-1;})()"
            : "(function(){var rs=document.querySelectorAll('.row');" +
              "return rs[1]?Math.ceil(rs[1].getBoundingClientRect().top):(rs[0]?Math.ceil(rs[0].getBoundingClientRect().height):-1);})()"
        let bottomBuffer: CGFloat = mini ? 4 : 24

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            self.webView.evaluateJavaScript(measureScript) { [weak self] result, _ in
                guard let self = self else { return }
                guard let targetCss = (result as? NSNumber)?.doubleValue, targetCss > 0 else { return }
                let newHeight = targetCss + Double(bottomBuffer) + Double(self.borderPad) * 2
                // macOS coordinates put the origin at the bottom-left with y growing upward,
                // opposite of WPF's top-left/y-down -- keep the TOP edge pinned in place (the
                // visual equivalent of the WPF version reasserting Top after changing Height).
                let top = self.frame.maxY
                var frame = self.frame
                frame.size.height = CGFloat(newHeight)
                frame.origin.y = top - frame.size.height
                frame.origin.x = self.pinnedX
                frame.size.width = self.pinnedWidth
                self.setFrame(frame, display: true)
            }
        }
    }
}
