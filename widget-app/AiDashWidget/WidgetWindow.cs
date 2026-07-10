// Ported from floating-widget.ps1's embedded Add-Type C# block. Logic is unchanged from the
// PowerShell/ps2exe version -- only the hosting shell changed (real dotnet build instead of a
// ps2exe-compiled script), which is what the WPF+WebView2+async combination actually needed to
// behave reliably.
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Wpf;
using Microsoft.Web.WebView2.Core;

namespace AiDashWidget {
  public class WidgetWindow : Window {
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    const int WM_NCLBUTTONDOWN = 0x00A1;
    const int HTCAPTION = 2;
    int _borderPad = 16;  // total width of the grabbable border strip around the WebView2
    int _resizeZone = 8;  // how close to the true window edge counts as "resize" rather than "move"
    bool _mini;            // mini mode: single-line bar, drag-to-move only, no resize (too small for corner handles)
    Border _border;

    public WidgetWindow(string url, string userDataFolder, double left, double top, double width, double height, bool mini) {
      _mini = mini;
      if (_mini) { _borderPad = 3; _resizeZone = 0; } // no room for a resize zone at ~20px tall
      Title = "AI Usage Dashboard Widget";
      WindowStyle = WindowStyle.None;
      AllowsTransparency = true;
      Background = Brushes.Transparent;
      Topmost = true;
      ResizeMode = _mini ? ResizeMode.NoResize : ResizeMode.CanResize;
      ShowInTaskbar = true;
      Left = left; Top = top; Width = width; Height = height;

      var creationProps = new CoreWebView2CreationProperties();
      creationProps.UserDataFolder = userDataFolder;

      var webView = new WebView2();
      webView.CreationProperties = creationProps;
      webView.DefaultBackgroundColor = System.Drawing.Color.Transparent;

      // The page (index.html, widget mode) posts a "drag" web message when the user presses
      // the left button on any non-interactive area. WebView2 swallows all mouse input over
      // its own rectangle, so the host can't see those presses directly -- letting the page
      // initiate the drag and translating it here into a native title-bar drag (HTCAPTION)
      // makes the whole content area grabbable, not just the thin border strip.
      webView.CoreWebView2InitializationCompleted += (s, e) => {
        if (!e.IsSuccess || webView.CoreWebView2 == null) {
          // Silently leaving the window blank here (as earlier versions did) is indistinguishable
          // from "nothing happened" to the user -- most commonly caused by another instance (or a
          // crashed/force-killed leftover) holding a lock on the same WebView2 UserDataFolder.
          // Surfacing the real exception message directly, rather than guessing, so whatever the
          // actual cause turns out to be next time is visible instead of hidden.
          MessageBox.Show(
            "WebView2 初始化失敗,小工具視窗會維持空白。\n\n" +
            "最常見原因:另一個小工具視窗(或當機後沒清乾淨的殘留行程)佔用了同一份設定檔資料夾。" +
            "請先關閉所有 AiDashWidget / AiDashWidgetMini 視窗,用工作管理員確認沒有殘留的 " +
            "msedgewebview2.exe 屬於本程式,再重新開啟。\n\n" +
            "錯誤訊息: " + (e.InitializationException?.Message ?? "(無)"),
            "AI Usage Dashboard Widget", MessageBoxButton.OK, MessageBoxImage.Warning);
          return;
        }
        webView.CoreWebView2.WebMessageReceived += (s2, e2) => {
          string msg;
          try { msg = e2.TryGetWebMessageAsString(); } catch { return; }
          if (msg != "drag") return;
          var hwndSource = PresentationSource.FromVisual(this) as HwndSource;
          if (hwndSource == null) return;
          ReleaseCapture();
          // SendMessage blocks until the native move loop ends (mouse released); the mousedown
          // that started this was preventDefault()ed in the page, so hand keyboard focus back
          // to the WebView2 afterwards or the mini widget's Up/Down provider switching dies.
          SendMessage(hwndSource.Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
          try { webView.Focus(); } catch { }
        };
      };

      // WebView2 owns a real native child window, which swallows all mouse input across its
      // whole rectangle -- if it fills the entire host window there is no surface left for the
      // parent to hit-test drag-move / edge-resize against. A thin Border margin around it
      // (technically part of the WPF window's own surface, not the child HWND) gives the user
      // something to grab. Clicking within _resizeZone px of the true window edge sends a native
      // WM_NCLBUTTONDOWN with the matching hit-test code so Windows handles it as a real resize
      // drag; clicking further in (but still on the border, not the WebView2) falls back to
      // DragMove() (move the window). _borderPad must be wider than _resizeZone or every point on
      // the border would count as an edge and there would be no way to just move the window.
      // In mini mode there's no room for a resize zone at all (_resizeZone=0), so every border
      // click is just a move.
      // Note: moving no longer depends on hitting this thin border -- the page itself posts a
      // "drag" web message on mousedown over non-interactive content (handled above), so the
      // border now mainly serves edge/corner *resizing*.
      _border = new Border();
      _border.Padding = new Thickness(_borderPad);
      _border.Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)); // ~invisible but non-zero alpha so it's still hit-testable
      _border.Child = webView;
      _border.MouseLeftButtonDown += Border_MouseLeftButtonDown;

      var root = new Grid();
      root.Children.Add(_border);
      if (!_mini) {
        // The border alone gives no visual clue that it's grabbable. Add small visible handle
        // squares at the four corners -- sitting right on top of the resize zone -- so the user
        // can actually see where to click-drag to resize. Diagonal resize cursor on hover too.
        // (Skipped in mini mode: fixed size by design, and there's no physical room for them.)
        root.Children.Add(MakeCornerHandle(HorizontalAlignment.Left, VerticalAlignment.Top, 13, Cursors.SizeNWSE, new CornerRadius(6, 0, 0, 0)));
        root.Children.Add(MakeCornerHandle(HorizontalAlignment.Right, VerticalAlignment.Top, 14, Cursors.SizeNESW, new CornerRadius(0, 6, 0, 0)));
        root.Children.Add(MakeCornerHandle(HorizontalAlignment.Left, VerticalAlignment.Bottom, 16, Cursors.SizeNESW, new CornerRadius(0, 0, 0, 6)));
        root.Children.Add(MakeCornerHandle(HorizontalAlignment.Right, VerticalAlignment.Bottom, 17, Cursors.SizeNWSE, new CornerRadius(0, 0, 6, 0)));
      }
      Content = root;

      // The default window height is just a placeholder -- real content height varies with
      // font rendering / provider data, which doesn't reliably match what test tools (e.g.
      // Playwright's headless Chromium) measure ahead of time. Once the page has actually
      // loaded real data in this real WebView2 instance, measure the target element (one full
      // provider card, or the single mini bar line) and resize the window to fit it exactly.
      // Self-calibrate: we already know the current WPF Height and can ask WebView2 for the
      // resulting window.innerHeight in CSS px, so the ratio between them gives the true
      // conversion factor on whatever machine/monitor this actually runs on.
      string measureScript = _mini
        ? "(function(){var el=document.getElementById('miniLine');return el?Math.ceil(el.getBoundingClientRect().height):-1;})()"
        : "(function(){var rs=document.querySelectorAll('.row');" +
          "return rs[1]?Math.ceil(rs[1].getBoundingClientRect().top):(rs[0]?Math.ceil(rs[0].getBoundingClientRect().height):-1);})()";
      int bottomBufferCss = _mini ? 4 : 24;
      webView.NavigationCompleted += async (s, e) => {
        try {
          await Task.Delay(2500); // let the initial /api/usage poll populate real data
          string targetStr = await webView.CoreWebView2.ExecuteScriptAsync(measureScript);
          string innerHStr = await webView.CoreWebView2.ExecuteScriptAsync("window.innerHeight");
          double targetCss, innerHCss;
          if (double.TryParse(targetStr, out targetCss) && double.TryParse(innerHStr, out innerHCss)
              && targetCss > 0 && innerHCss > 0) {
            double contentWpfUnits = Height - _borderPad * 2;
            if (contentWpfUnits > 0) {
              double scale = innerHCss / contentWpfUnits; // CSS px per WPF unit, measured live
              Height = ((targetCss + bottomBufferCss) / scale) + _borderPad * 2;
              Left = left; Top = top; Width = width;
            }
          }
        } catch { }
      };

      Loaded += (s, e) => { webView.Source = new Uri(url); };
    }

    Border MakeCornerHandle(HorizontalAlignment hAlign, VerticalAlignment vAlign, int htCode, Cursor cursor, CornerRadius radius) {
      var handle = new Border();
      handle.Width = _resizeZone * 2;
      handle.Height = _resizeZone * 2;
      handle.Margin = new Thickness(2);
      handle.HorizontalAlignment = hAlign;
      handle.VerticalAlignment = vAlign;
      handle.CornerRadius = radius;
      handle.Background = new SolidColorBrush(Color.FromArgb(1, 255, 255, 255)); // ~invisible but non-zero alpha so it's still hit-testable
      handle.Cursor = cursor;
      handle.MouseLeftButtonDown += (s, e) => {
        var hwndSource = PresentationSource.FromVisual(this) as HwndSource;
        if (hwndSource == null) return;
        ReleaseCapture();
        SendMessage(hwndSource.Handle, WM_NCLBUTTONDOWN, (IntPtr)htCode, IntPtr.Zero);
        e.Handled = true;
      };
      return handle;
    }

    void Border_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) {
      if (e.OriginalSource != _border) return; // ignore clicks that landed on the WebView2 child itself
      var pos = e.GetPosition(this);
      int ht = _mini ? 0 : HitTestEdge(pos);
      var hwndSource = PresentationSource.FromVisual(this) as HwndSource;
      if (hwndSource == null) return;
      if (ht != 0) {
        ReleaseCapture();
        SendMessage(hwndSource.Handle, WM_NCLBUTTONDOWN, (IntPtr)ht, IntPtr.Zero);
      } else {
        try { DragMove(); } catch { }
      }
    }

    int HitTestEdge(Point p) {
      bool left = p.X <= _resizeZone;
      bool right = p.X >= ActualWidth - _resizeZone;
      bool top = p.Y <= _resizeZone;
      bool bottom = p.Y >= ActualHeight - _resizeZone;
      if (top && left) return 13;     // HTTOPLEFT
      if (top && right) return 14;    // HTTOPRIGHT
      if (bottom && left) return 16;  // HTBOTTOMLEFT
      if (bottom && right) return 17; // HTBOTTOMRIGHT
      if (left) return 10;            // HTLEFT
      if (right) return 11;           // HTRIGHT
      if (top) return 12;             // HTTOP
      if (bottom) return 15;          // HTBOTTOM
      return 0;                       // treat as a plain move
    }
  }
}
