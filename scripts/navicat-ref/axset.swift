// Sets an accessibility attribute on a node of a Navicat window, addressed by REA's child-index path.
// Usage: swift axset.swift "<window title>" <path e.g. 1,0,7,0,8> select|value <text>|press|focus
import ApplicationServices
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.navicat.NavicatPremium").first
        ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.contains("Navicat") == true }) else {
    print("usage or app not found"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, name as CFString, &v); return v
}
// "clickat" mode: swift axset.swift clickat X Y — a left click at global screen coordinates.
if args[1] == "clickat", let x = Double(args[2]), let y = Double(args[3]) {
    let point = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x - 3, y: y), mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
    print("ok"); exit(0)
}
// "hover" mode: swift axset.swift hover X Y — moves the pointer there (reveals hover-only buttons).
if args[1] == "hover", let x = Double(args[2]), let y = Double(args[3]) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x - 2, y: y - 2), mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!.post(tap: .cghidEventTap)
    print("ok"); exit(0)
}
// "type" mode: swift axset.swift type "text" — types into the focused control; "key" mode: key code + modifiers.
if args[1] == "type" {
    for scalar in args[2].unicodeScalars {
        var units = Array(String(scalar).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cghidEventTap)
        }
        usleep(8_000)
    }
    print("ok"); exit(0)
}
if args[1] == "key", let code = UInt16(args[2]) {
    var flags: CGEventFlags = []
    if args.count > 3 {
        if args[3].contains("cmd") { flags.insert(.maskCommand) }
        if args[3].contains("shift") { flags.insert(.maskShift) }
        if args[3].contains("opt") { flags.insert(.maskAlternate) }
        if args[3].contains("ctrl") { flags.insert(.maskControl) }
    }
    // Press the modifier keys too: some editors (Scintilla) read the physical modifier state.
    let source = CGEventSource(stateID: .hidSystemState)
    let modifierKeys: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
    for (flag, key) in modifierKeys where flags.contains(flag) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!; e.flags = flags; e.post(tap: .cghidEventTap)
    }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
    for (flag, key) in modifierKeys.reversed() where flags.contains(flag) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!; e.post(tap: .cghidEventTap)
    }
    print("ok"); exit(0)
}
// "popup" mode: swift axset.swift popup "Item" ["Sub item"] presses an item of the open context menu.
if args[1] == "popup" {
    func findMenu(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if (attr(e, kAXRoleAttribute) as? String) == "AXMenu" { return e }
        guard depth < 3 else { return nil }
        for c in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] where (attr(c, kAXRoleAttribute) as? String) != "AXMenuBar" {
            if let m = findMenu(c, depth: depth + 1) { return m }
        }
        return nil
    }
    guard let menu = findMenu(root, depth: 0) else { print("no open menu"); exit(1) }
    var items = attr(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var path = Array(args.dropFirst(2))
    while !path.isEmpty {
        let title = path.removeFirst()
        guard let item = items.first(where: { (attr($0, kAXTitleAttribute) as? String) == title }) else {
            print("items:", items.compactMap { attr($0, kAXTitleAttribute) as? String }.filter { !$0.isEmpty }); exit(1)
        }
        if path.isEmpty { print(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? "ok" : "fail"); exit(0) }
        items = (attr(item, kAXChildrenAttribute) as? [AXUIElement])?.first.flatMap { attr($0, kAXChildrenAttribute) as? [AXUIElement] } ?? []
    }
    exit(0)
}
// "menu" mode: swift axset.swift menu "File" "Open Connection" presses a menu bar item by titles.
if args[1] == "menu" {
    var node = attr(root, kAXMenuBarAttribute) as! AXUIElement
    for title in args.dropFirst(2) {
        var children = attr(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        // Menu bar items hold one AXMenu child whose children are the items.
        if children.count == 1, (attr(children[0], kAXRoleAttribute) as? String) == "AXMenu" {
            children = attr(children[0], kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard let next = children.first(where: { (attr($0, kAXTitleAttribute) as? String) == title }) else {
            print("menu item not found: \(title); have: \(children.compactMap { attr($0, kAXTitleAttribute) as? String })"); exit(1)
        }
        node = next
    }
    print(AXUIElementPerformAction(node, kAXPressAction as CFString) == .success ? "ok" : "press failed")
    exit(0)
}
let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
// "#n" picks the n-th window (front to back); otherwise match the title.
let picked: AXUIElement? = args[1].hasPrefix("#") ? Int(args[1].dropFirst()).flatMap { $0 < windows.count ? windows[$0] : nil }
    : windows.first(where: { (attr($0, kAXTitleAttribute) as? String) == args[1] })
guard let window = picked else { print("window not found"); exit(1) }
if args[2] == "close" {
    guard let button = attr(window, kAXCloseButtonAttribute) else { print("no close button"); exit(1) }
    print(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success ? "ok" : "fail")
    exit(0)
}
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
case "selectall":
    let length = (attr(node, kAXValueAttribute) as? String)?.utf16.count ?? 0
    var range = CFRange(location: 0, length: length)
    result = AXUIElementSetAttributeValue(node, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!)
case "list":
    // Children of the node with role, title, help and description (one level, or two with "deep").
    func show(_ e: AXUIElement, _ prefix: String, _ depth: Int) {
        for (i, c) in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).enumerated() {
            let role = (attr(c, kAXRoleAttribute) as? String ?? "?").replacingOccurrences(of: "AX", with: "")
            let bits = [attr(c, kAXTitleAttribute) as? String, attr(c, kAXHelpAttribute) as? String, attr(c, kAXDescriptionAttribute) as? String,
                        (attr(c, kAXValueAttribute)).map { "\($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
            print("\(prefix)\(i) \(role) \(bits.joined(separator: " | "))")
            if depth > 0 && role != "Table" && role != "Outline" { show(c, prefix + "\(i).", depth - 1) }
        }
    }
    show(node, "", args.count > 4 ? 2 : 0)
    exit(0)
case "describe":
    print(attr(node, kAXRoleAttribute) as? String ?? "?", attr(node, kAXTitleAttribute) as? String ?? "", attr(node, kAXValueAttribute).map { "\($0)" } ?? "")
    exit(0)
case "context":
    // Opens the node's context menu and presses the item titled args[4] (or lists items when not found).
    AXUIElementPerformAction(node, kAXShowMenuAction as CFString)
    usleep(400_000)
    func findMenu(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if (attr(e, kAXRoleAttribute) as? String) == "AXMenu" { return e }
        guard depth < 14 else { return nil }
        for c in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let m = findMenu(c, depth: depth + 1) { return m } }
        return nil
    }
    let appChildren = (attr(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { (attr($0, kAXRoleAttribute) as? String) != "AXMenuBar" }
    guard let menu = findMenu(node, depth: 0) ?? findMenu(window, depth: 0) ?? appChildren.lazy.compactMap({ findMenu($0, depth: 0) }).first else {
        print("no menu"); exit(1)
    }
    var items = attr(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var path = args.count > 4 ? Array(args[4...]) : []
    while !path.isEmpty {
        let title = path.removeFirst()
        guard let item = items.first(where: { (attr($0, kAXTitleAttribute) as? String) == title }) else {
            print("items:", items.compactMap { attr($0, kAXTitleAttribute) as? String }.filter { !$0.isEmpty })
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            exit(1)
        }
        if path.isEmpty { result = AXUIElementPerformAction(item, kAXPressAction as CFString); print(result == .success ? "ok" : "AXError \(result.rawValue)"); exit(0) }
        let sub = (attr(item, kAXChildrenAttribute) as? [AXUIElement])?.first
        items = sub.flatMap { attr($0, kAXChildrenAttribute) as? [AXUIElement] } ?? []
    }
    result = .success
case "click", "dblclick", "rightclick":
    // Real mouse click at the node's center (for things AX can't do, like opening a connection).
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(node, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let z = attr(node, kAXSizeAttribute) { AXValueGetValue(z as! AXValue, .cgSize, &size) }
    var point = CGPoint(x: pos.x + min(size.width / 2, 60), y: pos.y + size.height / 2)
    if args.count > 4, args[4] == "right" { point.x = pos.x + size.width - 4 }
    let right = args[3] == "rightclick"
    let clicks = args[3] == "dblclick" ? 2 : 1
    for n in 1...clicks {
        let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left)!
        let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left)!
        down.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    result = .success
case "action":
    result = AXUIElementPerformAction(node, args[4] as CFString)
case "confirm": result = AXUIElementPerformAction(node, kAXConfirmAction as CFString)
default: print("unknown op"); exit(1)
}
print(result == .success ? "ok" : "AXError \(result.rawValue)")
