import Foundation

public struct LaunchOptions {
    public var width = 0
    public var height = 0
    public var margin = 16
    public var mini = false
    public var provider = ""
    public var baseUrl = "http://127.0.0.1:3789"

    public static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--mini": o.mini = true
            case "--width": i += 1; if i < args.count { o.width = Int(args[i]) ?? 0 }
            case "--height": i += 1; if i < args.count { o.height = Int(args[i]) ?? 0 }
            case "--margin": i += 1; if i < args.count { o.margin = Int(args[i]) ?? 16 }
            case "--provider": i += 1; if i < args.count { o.provider = args[i] }
            case "--base-url": i += 1; if i < args.count { o.baseUrl = args[i] }
            default: break
            }
            i += 1
        }
        return o
    }
}
