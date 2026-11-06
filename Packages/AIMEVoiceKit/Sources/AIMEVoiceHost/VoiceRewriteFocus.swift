import AppKit
import ApplicationServices
import Darwin
import Foundation
import InputMethodKit

// Focus resolution for rewrite. The AX read pattern is adapted from Type4Me's
// ReviseAccessibilityClient (MIT); see licenses/type4me.LICENSE.txt. Unlike that
// foreground app, this process is an input method, so the system-wide focused
// element is not a sufficient source. Paste, synthetic key events, and secure-input
// bypasses from that client are intentionally not used.

enum VoiceRewriteFocusText {
    /// `AXValue` is a String for plain fields and an attributed string for many
    /// AppKit text views (TextEdit rich text, Notes, Mail). Both are the field text.
    static func string(from value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        let ref = value as CFTypeRef
        guard CFGetTypeID(ref) == CFAttributedStringGetTypeID() else { return nil }
        return CFAttributedStringGetString((ref as! CFAttributedString)) as String
    }
}

enum VoiceRewriteFocusPolicy {
    enum Navigation: Equatable {
        case useAsField, searchInside, climb, stopSecure
    }

    static func isSecureControl(role: String, subrole: String) -> Bool {
        [role, subrole].contains { raw in
            let value = raw.lowercased()
            return value.contains("secure") || value.contains("password")
        }
    }

    static func isTextRole(_ role: String) -> Bool {
        role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String) || role == "AXSearchField"
    }

    static func isSingleLine(_ role: String) -> Bool {
        role == (kAXTextFieldRole as String) || role == "AXSearchField"
    }

    /// Containers are searched downward. Anything else that is not already a text
    /// field is climbed, because input methods often leave AX focus on a child run
    /// or cell of the real editor.
    static func navigation(role: String, subrole: String) -> Navigation {
        if isSecureControl(role: role, subrole: subrole) { return .stopSecure }
        if isTextRole(role) { return .useAsField }
        switch role {
        case "AXWindow", "AXSheet", "AXDrawer", "AXPopover", "AXScrollArea", "AXWebArea",
             "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXList", "AXOutline", "AXBrowser",
             "AXToolbar", "AXPage", "AXTabGroup", "AXScrollView":
            return .searchInside
        default:
            return .climb
        }
    }

    static func pathIsInsideAppBundle(_ path: String, appBundle: String) -> Bool {
        let root = appBundle.hasSuffix("/") ? String(appBundle.dropLast()) : appBundle
        guard !root.isEmpty else { return false }
        return path == root || path.hasPrefix(root + "/")
    }
}

/// Pure selection of the rewrite target. The AX reader fills this; tests cover the
/// cases that used to collapse into `noFocusedField`.
enum VoiceRewriteFocusResolver {
    struct App: Equatable {
        var processID: Int32
        var bundleID: String
        var bundlePath: String?
    }

    struct Process: Equatable {
        var processID: Int32
        var parentProcessID: Int32?
        var bundlePath: String?
    }

    enum Value: Equatable {
        case missing, nonText, text(String)
    }

    struct Node: Equatable {
        var token: String
        var processID: Int32
        var role: String
        var subrole: String = ""
        var value: Value = .missing
        var focused: Bool = false
        var selectedTextSettable: Bool = false
        var valueSettable: Bool = false
        var selectedRangeSettable: Bool = false
        var selection: NSRange? = nil
        var children: [Node] = []
        /// False when this node's child list was capped. A lone text control is then
        /// not assumed to be the editor, because a sibling may have been omitted.
        var childrenComplete: Bool = true
    }

    struct Probe: Equatable {
        var trusted: Bool = true
        var secureEventInput: Bool = false
        var selfProcessID: Int32
        var selfBundleID: String? = nil
        /// The IMK client named an app, but no single live process could be chosen.
        var clientBundleUnresolved: Bool = false
        var clientApplication: App? = nil
        var frontmost: App? = nil
        var focusedApplication: App? = nil
        var systemFocused: Node? = nil
        /// Keyed by the application element that was asked, not by a helper's pid.
        var applicationFocused: [Int32: Node] = [:]
        var processes: [Int32: Process] = [:]
    }

    struct Choice: Equatable {
        var token: String
        var processID: Int32
        var bundleID: String
        var value: String
        var selection: NSRange?
        var isEditable: Bool
        var isSecure: Bool
        var selectedTextSettable: Bool
        var valueSettable: Bool
        var singleLine: Bool
    }

    static func resolve(_ probe: Probe) -> Choice? {
        guard probe.trusted, !probe.secureEventInput, !probe.clientBundleUnresolved else { return nil }
        guard let target = targetApp(probe) else { return nil }
        var secureFallback: Choice?
        for root in roots(target: target, probe: probe) {
            guard let choice = choose(root, target: target, probe: probe) else { continue }
            if choice.isSecure { secureFallback = secureFallback ?? choice }
            else { return choice }
        }
        return secureFallback
    }

    /// Client app, then the frontmost user-facing app, then the AX focused application.
    /// Helper processes are never the target identity: their bundle id would not match
    /// the IMK client, and the snapshot would be rejected after a successful read.
    static func targetApp(_ probe: Probe) -> App? {
        for app in [probe.clientApplication, probe.frontmost, probe.focusedApplication] {
            guard let app, app.processID > 0, app.processID != probe.selfProcessID, !app.bundleID.isEmpty else { continue }
            if app.bundleID == probe.selfBundleID { continue }
            return app
        }
        return nil
    }

    static func owns(processID: Int32, target: App, selfProcessID: Int32, processes: [Int32: Process]) -> Bool {
        if processID <= 0 || processID == selfProcessID { return false }
        if processID == target.processID { return true }
        if let path = processes[processID]?.bundlePath, let targetPath = target.bundlePath,
           VoiceRewriteFocusPolicy.pathIsInsideAppBundle(path, appBundle: targetPath) {
            return true
        }
        var current = processID
        var seen: Set<Int32> = []
        var hops = 0
        while hops < 6, seen.insert(current).inserted, let parent = processes[current]?.parentProcessID, parent > 1 {
            if parent == selfProcessID { return false }
            if parent == target.processID { return true }
            if let path = processes[parent]?.bundlePath, let targetPath = target.bundlePath,
               VoiceRewriteFocusPolicy.pathIsInsideAppBundle(path, appBundle: targetPath) {
                return true
            }
            current = parent
            hops += 1
        }
        return false
    }

    private static func roots(target: App, probe: Probe) -> [Node] {
        var result: [Node] = []
        if let node = probe.applicationFocused[target.processID] { result.append(node) }
        if let system = probe.systemFocused,
           owns(processID: system.processID, target: target, selfProcessID: probe.selfProcessID, processes: probe.processes) {
            result.append(system)
        }
        return result
    }

    private static func choose(_ node: Node, target: App, probe: Probe) -> Choice? {
        guard owns(processID: node.processID, target: target, selfProcessID: probe.selfProcessID, processes: probe.processes) else { return nil }
        if VoiceRewriteFocusPolicy.isSecureControl(role: node.role, subrole: node.subrole) {
            return secureChoice(node, target: target)
        }
        if let choice = textChoice(node, target: target) { return choice }
        var texts: [Node] = []
        var secureFocused: Node?
        var seen = 0
        var complete = node.childrenComplete
        func walk(_ node: Node, depth: Int) {
            if seen >= 64 || depth > 6 { return }
            seen += 1
            if !node.childrenComplete { complete = false }
            guard owns(processID: node.processID, target: target, selfProcessID: probe.selfProcessID, processes: probe.processes) else { return }
            if VoiceRewriteFocusPolicy.isSecureControl(role: node.role, subrole: node.subrole) {
                if node.focused, secureFocused == nil { secureFocused = node }
                return
            }
            if textChoice(node, target: target) != nil {
                texts.append(node)
                return
            }
            guard depth < 6 else { return }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for child in node.children { walk(child, depth: 1) }
        let focused = texts.filter(\.focused)
        if focused.count == 1, let choice = textChoice(focused[0], target: target) { return choice }
        if focused.isEmpty, texts.count == 1, complete, let choice = textChoice(texts[0], target: target) { return choice }
        if focused.isEmpty, texts.isEmpty, let secure = secureFocused { return secureChoice(secure, target: target) }
        return nil
    }

    private static func textChoice(_ node: Node, target: App) -> Choice? {
        guard case .text(let text) = node.value else { return nil }
        guard !VoiceRewriteFocusPolicy.isSecureControl(role: node.role, subrole: node.subrole) else { return nil }
        let editable = VoiceRewriteFocusPolicy.isTextRole(node.role)
            || node.selectedTextSettable || node.valueSettable || node.selectedRangeSettable
        guard editable else { return nil }
        return Choice(token: node.token, processID: node.processID, bundleID: target.bundleID, value: text,
            selection: node.selection, isEditable: true, isSecure: false,
            selectedTextSettable: node.selectedTextSettable, valueSettable: node.valueSettable,
            singleLine: VoiceRewriteFocusPolicy.isSingleLine(node.role))
    }

    private static func secureChoice(_ node: Node, target: App) -> Choice {
        Choice(token: node.token, processID: node.processID, bundleID: target.bundleID, value: "",
            selection: nil, isEditable: false, isSecure: true, selectedTextSettable: false,
            valueSettable: false, singleLine: false)
    }
}

/// Live Accessibility read. Returns nil only when no field in the target app can be
/// resolved. Password controls come back as an unusable secure snapshot and their
/// value is never copied.
@MainActor enum VoiceRewriteAXFieldReader {
    private static let timeout: Float = 0.4

    static func snapshot(client: (any IMKTextInput)?) -> VoiceRewriteFieldSnapshot? {
        snapshot(bundleID: client?.bundleIdentifier(), processID: nil)
    }

    static func snapshot(bundleID: String?, processID: Int32?) -> VoiceRewriteFieldSnapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        if let found = read(bundleID: bundleID, processID: processID, enhanced: false) { return found }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        return read(bundleID: bundleID, processID: processID, enhanced: true)
    }

    private static func read(bundleID: String?, processID: Int32?, enhanced: Bool) -> VoiceRewriteFieldSnapshot? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        // A class, not an inout dictionary: `build` captures the map and also records
        // new pids into it. Swift rejects that overlap on a local var.
        let memory = ProcessMemory()
        track(selfPID, into: memory)
        let hinted = hintedApp(bundleID: bundleID, processID: processID, selfPID: selfPID, selfBundle: selfBundle, memory: memory)
        if hinted.unresolved { return nil }
        let frontmost = app(from: NSWorkspace.shared.frontmostApplication, selfPID: selfPID, memory: memory)
        // The IMK client already names the app. Don't wait on the system-wide focus query first.
        let focusedApp = hinted.app == nil ? focusedApplication(selfPID: selfPID, memory: memory) : nil
        let probeApps = VoiceRewriteFocusResolver.Probe(
            selfProcessID: selfPID, selfBundleID: selfBundle, clientBundleUnresolved: hinted.unresolved,
            clientApplication: hinted.app, frontmost: frontmost, focusedApplication: focusedApp, processes: memory.processes)
        guard let target = VoiceRewriteFocusResolver.targetApp(probeApps) else { return nil }
        track(target.processID, into: memory)
        // Type4Me takes the system-wide focused element as the field directly.
        // Try that first, scoped to the target app: when the editor itself holds
        // AX focus this succeeds where the tree walk below can fail on ambiguous
        // or deep trees (chat windows with several text controls). The walk stays
        // as the fallback for container focus.
        if let direct = directFieldSnapshot(target: target, selfPID: selfPID, memory: memory) {
            return direct
        }

        let application = AXUIElementCreateApplication(target.processID)
        setTimeout(application)
        if enhanced { enableEnhancedInterface(application) }

        var tokens: [String: AXUIElement] = [:]
        var nextID = 0
        var budget = 64
        func build(_ element: AXUIElement, depth: Int) -> VoiceRewriteFocusResolver.Node? {
            guard budget > 0 else { return nil }
            budget -= 1
            setTimeout(element)
            let elementPID = pid(of: element)
            guard elementPID != 0 else { return nil }
            track(elementPID, into: memory)
            guard VoiceRewriteFocusResolver.owns(processID: elementPID, target: target, selfProcessID: selfPID, processes: memory.processes) else { return nil }
            let role = copyString(kAXRoleAttribute, of: element) ?? ""
            let subrole = copyString(kAXSubroleAttribute, of: element) ?? ""
            let secure = VoiceRewriteFocusPolicy.isSecureControl(role: role, subrole: subrole)
            let value = secure ? VoiceRewriteFocusResolver.Value.missing : readValue(element, role: role)
            nextID += 1
            let token = "n\(nextID)"
            tokens[token] = element
            let usableText: Bool
            if case .text = value { usableText = VoiceRewriteFocusPolicy.isTextRole(role) } else { usableText = false }
            var children: [VoiceRewriteFocusResolver.Node] = []
            var childrenComplete = true
            if !secure, !usableText, depth < 6 {
                let listed = prioritizedChildren(element)
                childrenComplete = listed.count <= 32
                for child in listed.prefix(32) {
                    if let node = build(child, depth: depth + 1) { children.append(node) }
                    if budget <= 0 { childrenComplete = false; break }
                }
            }
            return VoiceRewriteFocusResolver.Node(
                token: token, processID: elementPID, role: role, subrole: subrole, value: value,
                focused: !secure && copyBool(kAXFocusedAttribute, of: element),
                selectedTextSettable: !secure && isSettable(kAXSelectedTextAttribute, of: element),
                valueSettable: !secure && isSettable(kAXValueAttribute, of: element),
                selectedRangeSettable: !secure && isSettable(kAXSelectedTextRangeAttribute, of: element),
                selection: secure ? nil : copySelection(element), children: children, childrenComplete: childrenComplete)
        }

        func snapshot(applicationNode: VoiceRewriteFocusResolver.Node?, systemNode: VoiceRewriteFocusResolver.Node?) -> VoiceRewriteFieldSnapshot? {
            var applicationNodes: [Int32: VoiceRewriteFocusResolver.Node] = [:]
            if let applicationNode { applicationNodes[target.processID] = applicationNode }
            let probe = VoiceRewriteFocusResolver.Probe(
                selfProcessID: selfPID, selfBundleID: selfBundle, clientBundleUnresolved: hinted.unresolved,
                clientApplication: hinted.app, frontmost: frontmost, focusedApplication: focusedApp,
                systemFocused: systemNode, applicationFocused: applicationNodes, processes: memory.processes)
            guard let choice = VoiceRewriteFocusResolver.resolve(probe), let element = tokens[choice.token] else { return nil }
            return VoiceRewriteFieldSnapshot(element: element, processID: choice.processID, bundleID: choice.bundleID,
                value: choice.value, selection: choice.selection, isEditable: choice.isEditable, isSecure: choice.isSecure,
                selectedTextSettable: choice.selectedTextSettable, valueSettable: choice.valueSettable, singleLine: choice.singleLine)
        }

        // Ask the target app directly. The system-wide focused element is a fallback:
        // from an input method it is often nil, or it is not the editor IMK is typing into.
        let applicationElement = copyElement(kAXFocusedUIElementAttribute, of: application)
            ?? copyElement(kAXFocusedWindowAttribute, of: application)
        if let applicationElement, let root = promotedRoot(applicationElement, target: target, selfPID: selfPID, memory: memory) {
            budget = 64
            if let node = build(root, depth: 0), let found = snapshot(applicationNode: node, systemNode: nil) {
                return found
            }
        }
        let system = AXUIElementCreateSystemWide()
        setTimeout(system)
        guard let systemElement = copyElement(kAXFocusedUIElementAttribute, of: system),
              let root = promotedRoot(systemElement, target: target, selfPID: selfPID, memory: memory),
              VoiceRewriteFocusResolver.owns(processID: pid(of: root), target: target, selfProcessID: selfPID, processes: memory.processes) else { return nil }
        budget = 64
        guard let node = build(root, depth: 0) else { return nil }
        return snapshot(applicationNode: nil, systemNode: node)
    }

    /// Type4Me-style direct path: the system-wide focused element is the field
    /// when it belongs to the target app and is usable as one. Scoping to the
    /// target app keeps the input-method safety the tree walk provides: another
    /// app's focused element, or this process's own UI, never becomes the field.
    /// Returns nil for anything else so the caller falls through to the walk.
    private static func directFieldSnapshot(target: VoiceRewriteFocusResolver.App, selfPID: Int32,
                                            memory: ProcessMemory) -> VoiceRewriteFieldSnapshot? {
        let system = AXUIElementCreateSystemWide()
        setTimeout(system)
        guard let element = copyElement(kAXFocusedUIElementAttribute, of: system) else { return nil }
        let elementPID = pid(of: element)
        track(elementPID, into: memory)
        guard VoiceRewriteFocusResolver.owns(processID: elementPID, target: target, selfProcessID: selfPID,
                                             processes: memory.processes) else { return nil }
        let role = copyString(kAXRoleAttribute, of: element) ?? ""
        let subrole = copyString(kAXSubroleAttribute, of: element) ?? ""
        guard !VoiceRewriteFocusPolicy.isSecureControl(role: role, subrole: subrole) else { return nil }
        guard case .text(let text) = readValue(element, role: role), text.utf16.count <= 100_000 else { return nil }
        let selectedTextSettable = isSettable(kAXSelectedTextAttribute, of: element)
        let valueSettable = isSettable(kAXValueAttribute, of: element)
        let selectedRangeSettable = isSettable(kAXSelectedTextRangeAttribute, of: element)
        let editable = VoiceRewriteFocusPolicy.isTextRole(role)
            || selectedTextSettable || valueSettable || selectedRangeSettable
        guard editable else { return nil }
        return VoiceRewriteFieldSnapshot(element: element, processID: elementPID, bundleID: target.bundleID,
            value: text, selection: copySelection(element), isEditable: true, isSecure: false,
            selectedTextSettable: selectedTextSettable, valueSettable: valueSettable,
            singleLine: VoiceRewriteFocusPolicy.isSingleLine(role))
    }

    /// Process graph shared by the nested AX walk. A reference type so recording a
    /// pid and reading the map are not overlapping accesses to one local variable.
    private final class ProcessMemory {
        var processes: [Int32: VoiceRewriteFocusResolver.Process] = [:]
    }

    private struct Hint {
        var app: VoiceRewriteFocusResolver.App?
        var unresolved: Bool
    }

    private static func hintedApp(bundleID: String?, processID: Int32?, selfPID: Int32, selfBundle: String?,
                                  memory: ProcessMemory) -> Hint {
        guard let bundleID, !bundleID.isEmpty, bundleID != selfBundle else { return Hint(app: nil, unresolved: false) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != selfPID && !$0.isTerminated }
        let chosen: NSRunningApplication?
        if let processID, let match = running.first(where: { $0.processIdentifier == processID }) {
            chosen = match
        } else if let active = running.first(where: \.isActive) {
            chosen = active
        } else if running.count == 1 {
            chosen = running[0]
        } else {
            chosen = nil
        }
        guard let chosen else { return Hint(app: nil, unresolved: true) }
        track(chosen.processIdentifier, into: memory)
        return Hint(app: VoiceRewriteFocusResolver.App(processID: chosen.processIdentifier, bundleID: bundleID,
            bundlePath: chosen.bundleURL?.path), unresolved: false)
    }

    private static func focusedApplication(selfPID: Int32, memory: ProcessMemory) -> VoiceRewriteFocusResolver.App? {
        let system = AXUIElementCreateSystemWide()
        setTimeout(system)
        guard let element = copyElement(kAXFocusedApplicationAttribute, of: system) else { return nil }
        return app(from: NSRunningApplication(processIdentifier: pid(of: element)), selfPID: selfPID, memory: memory)
    }

    private static func app(from running: NSRunningApplication?, selfPID: Int32, memory: ProcessMemory) -> VoiceRewriteFocusResolver.App? {
        guard let running, running.processIdentifier != selfPID, !running.isTerminated,
              let bundle = running.bundleIdentifier, !bundle.isEmpty,
              bundle != Bundle.main.bundleIdentifier else { return nil }
        track(running.processIdentifier, into: memory)
        return VoiceRewriteFocusResolver.App(processID: running.processIdentifier, bundleID: bundle, bundlePath: running.bundleURL?.path)
    }

    private static func promotedRoot(_ element: AXUIElement, target: VoiceRewriteFocusResolver.App, selfPID: Int32,
                                     memory: ProcessMemory) -> AXUIElement? {
        var current = element
        setTimeout(current)
        for _ in 0..<5 {
            let role = copyString(kAXRoleAttribute, of: current) ?? ""
            let subrole = copyString(kAXSubroleAttribute, of: current) ?? ""
            switch VoiceRewriteFocusPolicy.navigation(role: role, subrole: subrole) {
            case .stopSecure, .useAsField, .searchInside:
                return current
            case .climb:
                guard let parent = copyElement(kAXParentAttribute, of: current) else { return current }
                let parentPID = pid(of: parent)
                track(parentPID, into: memory)
                guard VoiceRewriteFocusResolver.owns(processID: parentPID, target: target, selfProcessID: selfPID, processes: memory.processes) else {
                    return current
                }
                current = parent
                setTimeout(current)
            }
        }
        return current
    }

    /// Chromium exposes its editor only after this attribute is set on the application
    /// element. It does not grant TCC permission and is not used as the AppKit path.
    private static func enableEnhancedInterface(_ application: AXUIElement) {
        ObjCException.guardCall("AXEnhancedUserInterface application") {
            _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        guard let window = copyElement(kAXFocusedWindowAttribute, of: application) else { return }
        let role = copyString(kAXRoleAttribute, of: window) ?? ""
        let subrole = copyString(kAXSubroleAttribute, of: window) ?? ""
        guard !VoiceRewriteFocusPolicy.isSecureControl(role: role, subrole: subrole) else { return }
        ObjCException.guardCall("AXEnhancedUserInterface window") {
            _ = AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func readValue(_ element: AXUIElement, role: String) -> VoiceRewriteFocusResolver.Value {
        let raw = copyRaw(kAXValueAttribute, of: element)
        if let text = VoiceRewriteFocusText.string(from: raw) { return .text(text) }
        if VoiceRewriteFocusPolicy.isTextRole(role), let text = stringForFullRange(element) { return .text(text) }
        return raw == nil ? .missing : .nonText
    }

    private static func stringForFullRange(_ element: AXUIElement) -> String? {
        guard let count = copyInt(copyRaw(kAXNumberOfCharactersAttribute, of: element)), count >= 0, count <= 100_000 else { return nil }
        if count == 0 { return "" }
        var range = CFRange(location: 0, length: count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw) == .success else { return nil }
        return VoiceRewriteFocusText.string(from: raw)
    }

    private static func prioritizedChildren(_ element: AXUIElement) -> [AXUIElement] {
        let children = copyChildren(element)
        guard children.count > 1 else { return children }
        let flagged = children.map { ($0, copyBool(kAXFocusedAttribute, of: $0)) }
        let focused = flagged.filter(\.1).map(\.0)
        guard !focused.isEmpty else { return children }
        let rest = flagged.filter { !$0.1 }.map(\.0)
        return focused + rest
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        let visible = elements(copyRaw(kAXVisibleChildrenAttribute, of: element))
        if !visible.isEmpty { return visible }
        return elements(copyRaw(kAXChildrenAttribute, of: element))
    }

    private static func elements(_ raw: CFTypeRef?) -> [AXUIElement] {
        guard let raw else { return [] }
        let list: [Any]
        if let items = raw as? [Any] { list = items }
        else if let items = raw as? NSArray { list = items.map { $0 } }
        else { return [] }
        return list.compactMap { item in
            let ref = item as CFTypeRef
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
    }

    private static func track(_ pid: Int32, into memory: ProcessMemory) {
        var current: Int32? = pid
        var hops = 0
        while let pid = current, hops < 6, memory.processes[pid] == nil {
            let parent = parentProcessID(pid)
            let running = NSRunningApplication(processIdentifier: pid)
            memory.processes[pid] = VoiceRewriteFocusResolver.Process(processID: pid, parentProcessID: parent, bundlePath: running?.bundleURL?.path)
            current = parent
            hops += 1
        }
    }

    private static func parentProcessID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        let ppidEnd = MemoryLayout<proc_bsdinfo>.offset(of: \.pbi_ppid)! + MemoryLayout<UInt32>.size
        guard size >= ppidEnd else { return nil }
        let parent = Int32(info.pbi_ppid)
        return parent > 0 ? parent : nil
    }

    private static func setTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return 0 }
        return pid
    }

    private static func copyRaw(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyString(_ name: String, of element: AXUIElement) -> String? {
        copyRaw(name, of: element) as? String
    }

    private static func copyElement(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let raw = copyRaw(name, of: element), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func copyBool(_ name: String, of element: AXUIElement) -> Bool {
        guard let raw = copyRaw(name, of: element) else { return false }
        if let number = raw as? NSNumber { return number.boolValue }
        return raw as? Bool ?? false
    }

    private static func copyInt(_ raw: CFTypeRef?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        return raw as? Int
    }

    private static func isSettable(_ name: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func copySelection(_ element: AXUIElement) -> NSRange? {
        guard let raw = copyRaw(kAXSelectedTextRangeAttribute, of: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
