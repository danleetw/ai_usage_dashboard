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
# If the dashboard server (server.js) isn't already running on -BaseUrl, this script starts
# it itself (hidden window, output appended to server.log) and waits up to ~10s for it to
# come up -- no need to run start.bat first. If Node.js itself is missing, it offers to
# install it via winget. Missing WebView2 SDK DLLs are offered the same way (ensure-webview2.ps1).
# Optional parameters:
#   -Width 380 -Height 480   window size (default fits one provider card; resize as needed)
#   -Margin 16               margin from the screen edge, in pixels
#   -Mini                    single-line ~20px-tall bar instead of a full card; fixed size,
#                            no corner resize handles
#   -Provider claude         which provider to show first in -Mini mode (defaults to the first
#                            one in your saved order); switch between providers with Up/Down
#                            arrow keys while the mini widget has focus
# To move the widget: press and drag anywhere on the content (buttons/inputs excluded) --
# the page posts a "drag" web message and the host turns it into a native HTCAPTION drag.
# To close the widget: Alt+F4 (there is no title bar / close button by design).

param(
  [int]$Width = 0,
  [int]$Height = 0,
  [int]$Margin = 16,
  [switch]$Mini,
  [string]$Provider = '',
  [string]$BaseUrl = 'http://127.0.0.1:3789'
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is only reliably populated when this file is executed as a genuine .ps1 by
# powershell.exe. It was found to also come back empty here when invoked via `&` from a
# ps2exe-compiled launcher exe (the launcher hosts its own separate PowerShell runtime), which
# made every path below it (floating-widget-lib, ensure-webview2.ps1, server.js, server.log)
# resolve against a null root and throw. Falling back through $MyInvocation and finally the
# current process's own exe path covers both the normal .ps1/.bat path and the compiled-exe path.
$root = if ($PSScriptRoot) { $PSScriptRoot }
  elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
  else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$libDir = Join-Path $root 'floating-widget-lib'
$url = "$BaseUrl/?widget=1"
if ($Mini) {
  $url += '&mini=1'
  if ($Provider) { $url += "&provider=$([Uri]::EscapeDataString($Provider))" }
}

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

# ---------- 0. Make sure the dashboard server is running (auto-start it if not) ----------
function Test-DashboardServer {
  try {
    Invoke-WebRequest -Uri "$BaseUrl/api/usage" -TimeoutSec 3 -UseBasicParsing | Out-Null
    return $true
  } catch {
    return $false
  }
}

if (-not (Test-DashboardServer)) {
  Write-Host "$BaseUrl not reachable -- starting the dashboard server automatically..." -ForegroundColor Yellow
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "Node.js not found." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      $nodeAnswer = Read-Host "Install Node.js LTS now via winget? (Y/N)"
      if ($nodeAnswer -match '^[Yy]') {
        Write-Host "Installing Node.js LTS..." -ForegroundColor Cyan
        winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        Write-Host "Node.js installed. Close this window, open a new terminal, and run this again (PATH needs to refresh)." -ForegroundColor Green
        exit 0
      }
    } else {
      Write-Host "winget not found -- install Node.js manually: https://nodejs.org/" -ForegroundColor Red
    }
    Write-Host "Node.js is required -- install it first: https://nodejs.org/" -ForegroundColor Red
    exit 1
  }
  # Launched via a hidden cmd.exe wrapper (not `node` directly) so stdout+stderr can be
  # merged and appended to server.log with plain cmd redirection; the node process keeps
  # running in the background after this script exits, same as start.bat does manually.
  $serverLog = Join-Path $root 'server.log'
  $cmdArgs = "/c node server.js >> `"$serverLog`" 2>&1"
  Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WorkingDirectory $root -WindowStyle Hidden | Out-Null

  $ready = $false
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-DashboardServer) { $ready = $true; break }
  }
  if (-not $ready) {
    Write-Host "Server did not come up in time -- run start.bat manually to see the error (or check $serverLog)." -ForegroundColor Red
    exit 1
  }
  Write-Host "Server started automatically." -ForegroundColor Green
}

$coreDll = Join-Path $libDir 'Microsoft.Web.WebView2.Core.dll'
$wpfDll = Join-Path $libDir 'Microsoft.Web.WebView2.Wpf.dll'
if (-not (Test-Path $coreDll) -or -not (Test-Path $wpfDll)) {
  & (Join-Path $root 'ensure-webview2.ps1')
}
if (-not (Test-Path $coreDll) -or -not (Test-Path $wpfDll)) {
  Write-Host "Missing WebView2 DLLs in $libDir -- see README for how to fetch them." -ForegroundColor Red
  exit 1
}
# WebView2Loader.dll (native) must be resolvable via the DLL search path.
$env:PATH = "$libDir;$env:PATH"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing, System.Windows.Forms
Add-Type -Path $coreDll
Add-Type -Path $wpfDll

# Resolve full file paths for the already-loaded assemblies instead of passing bare short
# names to -ReferencedAssemblies below. Short names resolve fine when run as a normal .ps1,
# but inside a ps2exe-compiled exe the C# compiler can't locate them by name (Add-Type then
# silently produces a type with no members, surfacing later as "The generated type does not
# define any public methods or content" when the type is used) -- full paths work in both.
function Resolve-AsmPath([string]$name) {
  ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $name } | Select-Object -First 1).Location
}
$refAssemblies = @(
  (Resolve-AsmPath 'PresentationFramework'), (Resolve-AsmPath 'PresentationCore'),
  (Resolve-AsmPath 'WindowsBase'), (Resolve-AsmPath 'System.Xaml'), (Resolve-AsmPath 'System.Drawing'),
  $coreDll, $wpfDll
)

Add-Type -ReferencedAssemblies $refAssemblies -TypeDefinition @'
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
        if (!e.IsSuccess || webView.CoreWebView2 == null) return;
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
      //
      // powershell.exe has no per-monitor-DPI-aware manifest, so WPF's device-independent units
      // don't map 1:1 onto WebView2's CSS pixels here (window.devicePixelRatio measured ~1.47,
      // not 1.0, and attempting to fix this at the process level via
      // SetProcessDpiAwarenessContext was a no-op -- powershell.exe's built-in manifest already
      // declares an awareness level that can't be overridden at runtime). Rather than hardcode a
      // guessed scale factor, self-calibrate: we already know the current WPF Height and can ask
      // WebView2 for the resulting window.innerHeight in CSS px, so the ratio between them gives
      // the true conversion factor on whatever machine/monitor this actually runs on.
      string measureScript = _mini
        ? "(function(){var el=document.getElementById('miniLine');return el?Math.ceil(el.getBoundingClientRect().height):-1;})()"
        : "(function(){var rs=document.querySelectorAll('.row');" +
          "return rs[1]?Math.ceil(rs[1].getBoundingClientRect().top):(rs[0]?Math.ceil(rs[0].getBoundingClientRect().height):-1);})()";
      int bottomBufferCss = _mini ? 4 : 24;
      webView.NavigationCompleted += async (s, e) => {
        try {
          await Task.Delay(2500); // let the initial /api/usage poll populate real data
          // ExecuteScriptAsync JSON-encodes whatever the script returns; returning plain numbers
          // (not an object via JSON.stringify) keeps the result a plain numeric string like "475",
          // avoiding a layer of escaped-quote JSON-in-JSON that a naive regex would miss.
          string targetStr = await webView.CoreWebView2.ExecuteScriptAsync(measureScript);
          string innerHStr = await webView.CoreWebView2.ExecuteScriptAsync("window.innerHeight");
          double targetCss, innerHCss;
          if (double.TryParse(targetStr, out targetCss) && double.TryParse(innerHStr, out innerHCss)
              && targetCss > 0 && innerHCss > 0) {
            double contentWpfUnits = Height - _borderPad * 2;
            if (contentWpfUnits > 0) {
              double scale = innerHCss / contentWpfUnits; // CSS px per WPF unit, measured live
              Height = ((targetCss + bottomBufferCss) / scale) + _borderPad * 2;
              // Some hosting environments (e.g. a ps2exe-compiled exe) fire an internal DPI
              // re-layout when Height changes here, which was observed to also drag Left/Top/
              // Width off their intended values (window ends up centered and undersized instead
              // of pinned top-right). Reasserting the original constructor values is a no-op
              // when nothing drifted (the normal .ps1/.bat path) and a fix when it did.
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
'@

Add-Type -AssemblyName System.Windows.Forms
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

if ($Width -le 0) { $Width = if ($Mini) { [int]($area.Width / 5) } else { 380 } }
if ($Height -le 0) { $Height = if ($Mini) { 28 } else { 480 } } # self-calibrated to real content after load either way

$x = $area.Right - $Width - $Margin
$y = $area.Top + $Margin
$userDataFolder = Join-Path $env:TEMP 'ai-dash-widget-webview2'

$window = New-Object AiDashWidget.WidgetWindow($url, $userDataFolder, [double]$x, [double]$y, [double]$Width, [double]$Height, [bool]$Mini)
Write-Host "Widget window created (top-right corner, transparent background). Alt+F4 to close." -ForegroundColor Green
$window.ShowDialog() | Out-Null
