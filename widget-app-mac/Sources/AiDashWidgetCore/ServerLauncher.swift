import Foundation
import AppKit

// Ported from floating-widget.ps1's "make sure the dashboard server is running" section /
// AiDashWidget's Program.cs (the Windows .NET port). Same behavior: check the dashboard is
// reachable, auto-start `node server.js` if not, offer to install Node.js if missing.
public enum ServerLauncher {
    public static func isDashboardReachable(baseUrl: String) -> Bool {
        guard let url = URL(string: baseUrl + "/api/usage") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, _, error in
            ok = (error == nil)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return ok
    }

    // Walks up from the executable's own directory looking for server.js (the project root's
    // marker file). Works whether this binary runs bare or from inside a .app bundle's
    // Contents/MacOS, and regardless of how many folders deep it's copied to -- mirrors
    // AiDashWidget's Program.cs FindProjectRoot on the Windows side.
    public static func findProjectRoot() -> String {
        var dir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("server.js")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return dir.path
    }

    // A GUI app launched by double-clicking in Finder does NOT inherit the interactive shell's
    // PATH (no .zprofile/.zshrc sourced) -- Node installed via nvm/Homebrew can be invisible to
    // a plain Process lookup even though `node` works fine in Terminal. Running through a login
    // shell (`zsh -l -c`) sources the user's profile first, same fix in spirit to the Windows
    // side needing `where`/PATH refresh handling.
    private static func runInLoginShell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, "")
        }
    }

    public static func commandExists(_ cmd: String) -> Bool {
        runInLoginShell("command -v \(cmd)").status == 0
    }

    public static func ensureNodeAndStartServer(baseUrl: String) -> Bool {
        let root = findProjectRoot()

        if !commandExists("node") {
            let hasBrew = commandExists("brew")
            let alert = NSAlert()
            alert.messageText = "找不到 Node.js"
            alert.alertStyle = .informational
            if hasBrew {
                alert.informativeText = "要現在透過 Homebrew 安裝 Node.js 嗎?"
                alert.addButton(withTitle: "安裝")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    _ = runInLoginShell("brew install node")
                    let done = NSAlert()
                    done.messageText = "Node.js 安裝完成"
                    done.informativeText = "請關閉並重新開啟這個 App(PATH 需要刷新)。"
                    done.runModal()
                }
            } else {
                alert.informativeText = "找不到 Homebrew,請手動安裝 Node.js: https://nodejs.org/"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
            return false
        }

        // Launched via a login shell (not `node` directly) so PATH resolves the same way the
        // existence check above did, and so stdout+stderr can be redirected into server.log with
        // plain shell syntax; the node process keeps running in the background after this
        // process exits, same as start.bat/floating-widget.ps1 do on Windows.
        let serverLog = root + "/server.log"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "node server.js >> \"\(serverLog)\" 2>&1"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        do {
            try process.run()
        } catch {
            return false
        }

        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            if isDashboardReachable(baseUrl: baseUrl) { return true }
        }

        let alert = NSAlert()
        alert.messageText = "伺服器沒有在時限內啟動"
        alert.informativeText = "請檢查 \(serverLog)"
        alert.alertStyle = .critical
        alert.runModal()
        return false
    }
}
