# AI Usage Dashboard - Floating Desktop Widget (Windows only), WPF + WebView2 edition
#
# Why WPF+WebView2 instead of just launching Edge in --app mode:
#   1) Edge/Chromium app-mode windows always draw their own minimal title bar (icon,
#      title, minimize/restore/close) as part of the page content area -- it's not a
#      native window decoration, so there is no way to strip it via Win32 APIs from
#      outside the process.
#   2) Chromium windows render via GPU DirectComposition, so applying a classic layered
#      window (SetLayeredWindowAttributes) from an external process has no visible
#      effect -- this is a well-known limitation, not specific to this script.
# WPF solves both: we own window creation, so WindowStyle=None gives a truly chromeless
# window, and WebView2's DefaultBackgroundColor=Transparent (combined with the host
# window's AllowsTransparency) gives real per-pixel transparency -- only the dashboard's
# own background shows the desktop through it; card backgrounds/text/bars stay opaque
# and crisp.
#
# Requires the WebView2 SDK DLLs in .\floating-widget-lib\ (from the official
# Microsoft.Web.WebView2 NuGet package -- downloaded once; the WebView2 *runtime* itself
# already ships with Windows/Edge, this is just the small wrapper library used to embed it).
#
# Usage: double-click floating-widget.bat, or run directly:
#   powershell -ExecutionPolicy Bypass -File floating-widget.ps1
# Optional parameters:
#   -Width 380 -Height 480   window size (default fits one provider card; resize as needed)
#   -Margin 16               margin from the screen edge, in pixels
# To close the widget: Alt+F4 (there is no title bar / close button by design).

param(
  [int]$Width = 380,
  [int]$Height = 480,
  [int]$Margin = 16,
  [string]$BaseUrl = 'http://127.0.0.1:3789'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$libDir = Join-Path $root 'floating-widget-lib'
$url = "$BaseUrl/?widget=1"

# powershell.exe has no DPI-awareness manifest, so Windows DPI-virtualizes (bitmap-stretches)
# any window it creates -- this was found to make WebView2's CSS pixels (devicePixelRatio ~1.47)
# not match the WPF window's device-independent units at all, throwing off any attempt to size
# the window to fit real rendered content. Declaring per-monitor-v2 DPI awareness for this
# process, before any window is created, fixes it at the source instead of fudging pixel math.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DpiAwareness {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
'@
try { [DpiAwareness]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { } # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2

# ---------- 0. Make sure the dashboard server is running ----------
try {
  Invoke-WebRequest -Uri "$BaseUrl/api/usage" -TimeoutSec 3 -UseBasicParsing | Out-Null
} catch {
  Write-Host "Could not reach $BaseUrl -- start the server first (start.bat)." -ForegroundColor Yellow
  exit 1
}

$coreDll = Join-Path $libDir 'Microsoft.Web.WebView2.Core.dll'
$wpfDll = Join-Path $libDir 'Microsoft.Web.WebView2.Wpf.dll'
if (-not (Test-Path $coreDll) -or -not (Test-Path $wpfDll)) {
  Write-Host "Missing WebView2 DLLs in $libDir -- see README for how to fetch them." -ForegroundColor Red
  exit 1
}
# WebView2Loader.dll (native) must be resolvable via the DLL search path.
$env:PATH = "$libDir;$env:PATH"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing, System.Windows.Forms
Add-Type -Path $coreDll
Add-Type -Path $wpfDll

Add-Type -ReferencedAssemblies @(
  'PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Drawing',
  $coreDll, $wpfDll
) -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Wpf;

namespace AiDashWidget {
  public class WidgetWindow : Window {
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    const int WM_NCLBUTTONDOWN = 0x00A1;
    const int BorderPad = 16;   // total width of the grabbable border strip around the WebView2
    const int ResizeZone = 8;   // how close to the true window edge counts as "resize" rather than "move"
    Border _border;

    public WidgetWindow(string url, string userDataFolder, double left, double top, double width, double height) {
      Title = "AI Usage Dashboard Widget";
      WindowStyle = WindowStyle.None;
      AllowsTransparency = true;
      Background = Brushes.Transparent;
      Topmost = true;
      ResizeMode = ResizeMode.CanResize;
      ShowInTaskbar = true;
      Left = left; Top = top; Width = width; Height = height;

      var creationProps = new CoreWebView2CreationProperties();
      creationProps.UserDataFolder = userDataFolder;

      var webView = new WebView2();
      webView.CreationProperties = creationProps;
      webView.DefaultBackgroundColor = System.Drawing.Color.Transparent;

      // WebView2 owns a real native child window, which swallows all mouse input across its
      // whole rectangle -- if it fills the entire host window there is no surface left for the
      // parent to hit-test drag-move / edge-resize against. A thin Border margin around it
      // (technically part of the WPF window's own surface, not the child HWND) gives the user
      // something to grab. Clicking within ResizeZone px of the true window edge sends a native
      // WM_NCLBUTTONDOWN with the matching hit-test code so Windows handles it as a real resize
      // drag; clicking further in (but still on the border, not the WebView2) falls back to
      // DragMove() (move the window). BorderPad must be wider than ResizeZone or every point on
      // the border would count as an edge and there would be no way to just move the window.
      _border = new Border();
      _border.Padding = new Thickness(BorderPad);
      _border.Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)); // ~invisible but non-zero alpha so it's still hit-testable
      _border.Child = webView;
      _border.MouseLeftButtonDown += Border_MouseLeftButtonDown;

      // The border alone gives no visual clue that it's grabbable. Add small visible handle
      // squares at the four corners -- sitting right on top of the resize zone -- so the user
      // can actually see where to click-drag to resize. Diagonal resize cursor on hover too.
      var root = new Grid();
      root.Children.Add(_border);
      root.Children.Add(MakeCornerHandle(HorizontalAlignment.Left, VerticalAlignment.Top, 13, Cursors.SizeNWSE, new CornerRadius(6, 0, 0, 0)));
      root.Children.Add(MakeCornerHandle(HorizontalAlignment.Right, VerticalAlignment.Top, 14, Cursors.SizeNESW, new CornerRadius(0, 6, 0, 0)));
      root.Children.Add(MakeCornerHandle(HorizontalAlignment.Left, VerticalAlignment.Bottom, 16, Cursors.SizeNESW, new CornerRadius(0, 0, 0, 6)));
      root.Children.Add(MakeCornerHandle(HorizontalAlignment.Right, VerticalAlignment.Bottom, 17, Cursors.SizeNWSE, new CornerRadius(0, 0, 6, 0)));
      Content = root;

      // The default window height is just a placeholder -- real content height varies with
      // font rendering / provider data, which doesn't reliably match what test tools (e.g.
      // Playwright's headless Chromium) measure ahead of time. Once the page has actually
      // loaded real data in this real WebView2 instance, measure the first provider card and
      // resize the window to fit it exactly (repeats on each navigation/reload).
      //
      // powershell.exe has no per-monitor-DPI-aware manifest, so WPF's device-independent units
      // don't map 1:1 onto WebView2's CSS pixels here (window.devicePixelRatio measured ~1.47,
      // not 1.0, and attempting to fix this at the process level via
      // SetProcessDpiAwarenessContext was a no-op -- powershell.exe's built-in manifest already
      // declares an awareness level that can't be overridden at runtime). Rather than hardcode a
      // guessed scale factor, self-calibrate: we already know the current WPF Height and can ask
      // WebView2 for the resulting window.innerHeight in CSS px, so the ratio between them gives
      // the true conversion factor on whatever machine/monitor this actually runs on.
      webView.NavigationCompleted += async (s, e) => {
        try {
          await Task.Delay(2500); // let the initial /api/usage poll populate real data
          // ExecuteScriptAsync JSON-encodes whatever the script returns; returning plain numbers
          // (not an object via JSON.stringify) keeps the result a plain numeric string like "475",
          // avoiding a layer of escaped-quote JSON-in-JSON that a naive regex would miss.
          string targetStr = await webView.CoreWebView2.ExecuteScriptAsync(
            "(function(){var rs=document.querySelectorAll('.row');" +
            "return rs[1]?Math.ceil(rs[1].getBoundingClientRect().top):(rs[0]?Math.ceil(rs[0].getBoundingClientRect().height):-1);})()");
          string innerHStr = await webView.CoreWebView2.ExecuteScriptAsync("window.innerHeight");
          double targetCss, innerHCss;
          if (double.TryParse(targetStr, out targetCss) && double.TryParse(innerHStr, out innerHCss)
              && targetCss > 0 && innerHCss > 0) {
            double contentWpfUnits = Height - BorderPad * 2;
            if (contentWpfUnits > 0) {
              double scale = innerHCss / contentWpfUnits; // CSS px per WPF unit, measured live
              Height = ((targetCss + 24) / scale) + BorderPad * 2; // +24 CSS px bottom buffer
            }
          }
        } catch { }
      };

      Loaded += (s, e) => { webView.Source = new Uri(url); };
    }

    Border MakeCornerHandle(HorizontalAlignment hAlign, VerticalAlignment vAlign, int htCode, Cursor cursor, CornerRadius radius) {
      var handle = new Border();
      handle.Width = ResizeZone * 2;
      handle.Height = ResizeZone * 2;
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
      int ht = HitTestEdge(pos);
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
      bool left = p.X <= ResizeZone;
      bool right = p.X >= ActualWidth - ResizeZone;
      bool top = p.Y <= ResizeZone;
      bool bottom = p.Y >= ActualHeight - ResizeZone;
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
'@

Add-Type -AssemblyName System.Windows.Forms
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x = $area.Right - $Width - $Margin
$y = $area.Top + $Margin
$userDataFolder = Join-Path $env:TEMP 'ai-dash-widget-webview2'

$window = New-Object AiDashWidget.WidgetWindow($url, $userDataFolder, [double]$x, [double]$y, [double]$Width, [double]$Height)
Write-Host "Widget window created (top-right corner, transparent background). Alt+F4 to close." -ForegroundColor Green
$window.ShowDialog() | Out-Null
