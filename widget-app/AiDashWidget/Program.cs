// Real WPF app replacing the ps2exe-compiled floating-widget.ps1 launcher. Ported logic:
// server auto-start / Node.js detection from floating-widget.ps1's "make sure the dashboard
// server is running" section. WebView2 DLLs no longer need manual management (floating-widget-lib
// + ensure-webview2.ps1) -- the Microsoft.Web.WebView2 NuGet package handles that at build time.
using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Windows;

namespace AiDashWidget {
  public class Program {
    [STAThread]
    public static int Main(string[] args) {
      int width = 0, height = 0, margin = 16;
      bool mini = false;
      string provider = "";
      string baseUrl = "http://127.0.0.1:3789";

      for (int i = 0; i < args.Length; i++) {
        switch (args[i]) {
          case "--mini": mini = true; break;
          case "--width": if (i + 1 < args.Length) int.TryParse(args[++i], out width); break;
          case "--height": if (i + 1 < args.Length) int.TryParse(args[++i], out height); break;
          case "--margin": if (i + 1 < args.Length) int.TryParse(args[++i], out margin); break;
          case "--provider": if (i + 1 < args.Length) provider = args[++i]; break;
          case "--base-url": if (i + 1 < args.Length) baseUrl = args[++i]; break;
        }
      }

      // A self-contained publish output has to keep several native DLLs (WebView2Loader.dll,
      // wpfgfx_cor3.dll, etc.) alongside the exe, so the exe can't just be copied out on its
      // own into the dashboard project root next to server.js -- it has to keep its whole
      // publish folder together, wherever that ends up. Walking up from the exe's own
      // directory to find server.js (the project root's marker file) means the exe works
      // regardless of which folder depth it's published/copied to.
      string root = FindProjectRoot(AppContext.BaseDirectory);
      string url = baseUrl + "/?widget=1";
      if (mini) {
        url += "&mini=1";
        if (!string.IsNullOrEmpty(provider)) url += "&provider=" + Uri.EscapeDataString(provider);
      }

      if (!TestDashboardServer(baseUrl)) {
        if (!EnsureNodeAndStartServer(root, baseUrl)) return 1;
      }

      var area = System.Windows.Forms.Screen.PrimaryScreen.WorkingArea;
      if (width <= 0) width = mini ? area.Width / 5 : 380;
      if (height <= 0) height = mini ? 28 : 480; // self-calibrated to real content after load either way

      double x = area.Right - width - margin;
      double y = area.Top + margin;
      string userDataFolder = Path.Combine(Path.GetTempPath(), "ai-dash-widget-webview2");

      var window = new WidgetWindow(url, userDataFolder, x, y, width, height, mini);
      var app = new Application();
      app.Run(window);
      return 0;
    }

    static string FindProjectRoot(string startDir) {
      var dir = new DirectoryInfo(startDir);
      while (dir != null) {
        if (File.Exists(Path.Combine(dir.FullName, "server.js"))) return dir.FullName;
        dir = dir.Parent;
      }
      return startDir;
    }

    static bool TestDashboardServer(string baseUrl) {
      try {
        using (var client = new HttpClient { Timeout = TimeSpan.FromSeconds(3) }) {
          var resp = client.GetAsync(baseUrl + "/api/usage").GetAwaiter().GetResult();
          return true;
        }
      } catch {
        return false;
      }
    }

    static bool EnsureNodeAndStartServer(string root, string baseUrl) {
      if (!IsCommandAvailable("node")) {
        if (IsCommandAvailable("winget")) {
          var result = MessageBox.Show(
            "找不到 Node.js。要現在透過 winget 安裝 Node.js LTS 嗎?",
            "AI Usage Dashboard Widget", MessageBoxButton.YesNo, MessageBoxImage.Question);
          if (result == MessageBoxResult.Yes) {
            RunProcessAndWait("winget", "install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements");
            MessageBox.Show("Node.js 已安裝完成。請關閉這個視窗、開新的終端機後再重新執行一次(PATH 需要刷新)。",
              "AI Usage Dashboard Widget", MessageBoxButton.OK, MessageBoxImage.Information);
          }
        } else {
          MessageBox.Show("找不到 winget，請手動安裝 Node.js: https://nodejs.org/",
            "AI Usage Dashboard Widget", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        return false;
      }

      // Launched via a hidden cmd.exe wrapper (not `node` directly) so stdout+stderr can be
      // merged and appended to server.log with plain cmd redirection; the node process keeps
      // running in the background after this process exits, same as start.bat does manually.
      string serverLog = Path.Combine(root, "server.log");
      var psi = new ProcessStartInfo {
        FileName = "cmd.exe",
        Arguments = $"/c node server.js >> \"{serverLog}\" 2>&1",
        WorkingDirectory = root,
        WindowStyle = ProcessWindowStyle.Hidden,
        UseShellExecute = true,
      };
      Process.Start(psi);

      for (int i = 0; i < 20; i++) {
        Thread.Sleep(500);
        if (TestDashboardServer(baseUrl)) return true;
      }
      MessageBox.Show($"伺服器沒有在時限內啟動，請檢查 {serverLog}",
        "AI Usage Dashboard Widget", MessageBoxButton.OK, MessageBoxImage.Error);
      return false;
    }

    static bool IsCommandAvailable(string cmd) {
      try {
        var psi = new ProcessStartInfo {
          FileName = "where",
          Arguments = cmd,
          UseShellExecute = false,
          RedirectStandardOutput = true,
          RedirectStandardError = true,
          CreateNoWindow = true,
        };
        using (var p = Process.Start(psi)) {
          p.WaitForExit(3000);
          return p.ExitCode == 0;
        }
      } catch {
        return false;
      }
    }

    static void RunProcessAndWait(string fileName, string arguments) {
      var psi = new ProcessStartInfo { FileName = fileName, Arguments = arguments, UseShellExecute = true };
      using (var p = Process.Start(psi)) { p.WaitForExit(); }
    }
  }
}
