// Prints the id of a process's main window (its largest), for `screencapture -l <id>`. The menu bar
// strips are windows too; one id only, since screencapture takes any extra one as a file name.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: winid.swift <pid>\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let area = { (w: [String: Any]) -> Double in
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
let main = windows.filter {
    $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0
}.max { area($0) < area($1) }
guard let main, let id = main[kCGWindowNumber as String] else { exit(1) }
print(id)
