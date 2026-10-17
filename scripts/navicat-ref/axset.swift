// Sets an accessibility attribute on a node of a Navicat window, addressed by REA's child-index path.
// Usage: swift axset.swift "<window title>" <path e.g. 1,0,7,0,8> select|value <text>|press|focus
import ApplicationServices
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.navicat.NavicatPremium").first
        ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.contains("Navicat") == true }) else {
    print("usage or app not found"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, name as CFString, &v); return v
}
let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
// "#n" picks the n-th window (front to back); otherwise match the title.
let picked: AXUIElement? = args[1].hasPrefix("#") ? Int(args[1].dropFirst()).flatMap { $0 < windows.count ? windows[$0] : nil }
    : windows.first(where: { (attr($0, kAXTitleAttribute) as? String) == args[1] })
guard let window = picked else { print("window not found"); exit(1) }
var node = window
for index in args[2].split(separator: ",").compactMap({ Int($0) }) {
    let children = attr(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    guard index < children.count else { print("bad path at \(index)"); exit(1) }
    node = children[index]
}
let result: AXError
switch args[3] {
case "select": result = AXUIElementSetAttributeValue(node, kAXSelectedAttribute as CFString, kCFBooleanTrue)
case "value": result = AXUIElementSetAttributeValue(node, kAXValueAttribute as CFString, args[4] as CFString)
case "focus": result = AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
case "press": result = AXUIElementPerformAction(node, kAXPressAction as CFString)
case "describe":
    print(attr(node, kAXRoleAttribute) as? String ?? "?", attr(node, kAXTitleAttribute) as? String ?? "", attr(node, kAXValueAttribute).map { "\($0)" } ?? "")
    exit(0)
case "confirm": result = AXUIElementPerformAction(node, kAXConfirmAction as CFString)
default: print("unknown op"); exit(1)
}
print(result == .success ? "ok" : "AXError \(result.rawValue)")
