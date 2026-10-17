// Captures every on-screen window owned by Komizo: swift scripts/window-shot.swift <out-dir> [prefix]
import CoreGraphics
import Foundation
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let prefix = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "shot"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var index = 0
for info in list where (info[kCGWindowOwnerName as String] as? String) == "Komizo" && (info[kCGWindowLayer as String] as? Int ?? 0) < 25 {
    guard let id = info[kCGWindowNumber as String] as? Int else { continue }
    let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
    guard (bounds["Width"] ?? 0) > 60 else { continue }
    let path = "\(out)/\(prefix)-\(index).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", "\(id)", path]
    try task.run(); task.waitUntilExit()
    print("\(path) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0)) \(info[kCGWindowName as String] as? String ?? "")")
    index += 1
}
