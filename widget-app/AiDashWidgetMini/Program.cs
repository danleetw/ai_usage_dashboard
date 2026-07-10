// Thin double-click launcher: just relaunches AiDashWidget.exe with --mini so there are two
// separate double-clickable exes (full card vs mini bar), matching floating-widget.bat vs
// floating-widget-mini.bat. Deliberately not WPF -- it has no UI of its own, it only forwards.
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace AiDashWidgetMini {
  public class Program {
    public static int Main(string[] args) {
      string dir = AppContext.BaseDirectory;
      string mainExe = Path.Combine(dir, "AiDashWidget.exe");
      if (!File.Exists(mainExe)) {
        System.Windows.Forms.MessageBox.Show($"找不到 {mainExe}，請確認兩個 exe 放在同一個資料夾。",
          "AI Usage Dashboard Mini Widget");
        return 1;
      }
      string forwardedArgs = "--mini " + string.Join(" ", args.Select(a => "\"" + a + "\""));
      var psi = new ProcessStartInfo {
        FileName = mainExe,
        Arguments = forwardedArgs,
        UseShellExecute = true,
      };
      Process.Start(psi);
      return 0;
    }
  }
}
