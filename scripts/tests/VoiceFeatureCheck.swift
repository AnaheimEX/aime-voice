import Foundation
import InputMethodKit
import AppKit
import AIMEVoice
import AIMEVoiceHost

// External IMK transport boundary. A generated string cannot prove client identity.
final class Document {
    var text = "前文"
    var selection = NSRange(location: 2, length: 0)
}
final class Client: NSObject, IMKTextInput {
    let document: Document
    var identity: String
    var generatesIdentifier = false
    var application = "app.test.editor"
    var currentSelectionOnly = false
    init(_ document: Document, id: String = "field-a") { self.document = document; identity = id }
    func insertText(_ value: Any!, replacementRange: NSRange) {
        if currentSelectionOnly && replacementRange.location != NSNotFound { return }
        let range = replacementRange.location == NSNotFound ? document.selection : replacementRange
        let text = value as! String
        document.text = (document.text as NSString).replacingCharacters(in: range, with: text)
        document.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
    }
    func selectedRange() -> NSRange { document.selection }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard range.location != NSNotFound, NSMaxRange(range) <= (document.text as NSString).length else { return nil }
        return NSAttributedString(string: (document.text as NSString).substring(with: range))
    }
    func uniqueClientIdentifierString() -> String! { generatesIdentifier ? UUID().uuidString : identity }
    func bundleIdentifier() -> String! { application }
    func setMarkedText(_ value: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func length() -> Int { (document.text as NSString).length }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ identifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}


private final class Service: NSObject, VoiceServiceProtocol, @unchecked Sendable {
    var requests: [VoiceRequest] = []
    var stopped: [String] = []
    func ping(_ reply: @escaping () -> Void) { reply() }
    func warmUp(_ reply: @escaping (Bool) -> Void) { reply(false) }
    func start(_ data: Data, reply: @escaping (Bool, String) -> Void) {
        requests.append(try! JSONDecoder().decode(VoiceRequest.self, from: data)); reply(true, "")
    }
    func stop(_ id: String) { stopped.append(id) }
    func cancel(_ id: String) {}
}
private final class Connection: NSXPCConnection, @unchecked Sendable {
    let service = Service()
    override func resume() {}
    override func invalidate() {}
    override var remoteObjectProxy: Any { service }
    override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any { service }
    func send(_ event: VoiceEvent) { (exportedObject as? any VoiceObserverProtocol)?.receive(try! JSONEncoder().encode(event)) }
}
@MainActor private final class Host: VoiceHost {
    let owner = InputOwner()
    let client = Client(Document())
    var snapshotReads = 0
    var canCommit = true
    var canStart = true
    var messages: [String] = []
    var effects: [String] = []
    func snapshot(for owner: InputOwner) -> InputSnapshot? {
        snapshotReads += 1
        guard owner == self.owner else { return nil }
        return InputSnapshot(client: client, canStart: canStart, canCommit: canCommit)
    }
    func present(_ effect: HostPresentation, for owner: InputOwner) {
        switch effect {
        case .status(let message): messages.append(message); effects.append("status:" + message)
        case .hideCandidates: effects.append("hideCandidates")
        case .restorePanel: effects.append("restorePanel")
        }
    }
}
@main struct VoiceFeatureCheck {
    @MainActor static func settle() async throws { for _ in 0..<100 { try await Task.sleep(for: .milliseconds(2)) } }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = VoiceSettings(); settings.enabled = true; settings.mode = "polish"
        let processing = try JSONDecoder().decode(VoicePolishObservation.Processing.self,
            from: Data(#"{"source":1,"milliseconds":500,"finalCorrections":0}"#.utf8))
        let url = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: url)
        let host = Host()
        let connection = Connection(machServiceName: "test.voice.feature")
        let feature = VoiceFeature(host: host, settingsURL: url, makeConnection: { connection }, feedback: { _ in }, captureAnchor: { _ in nil })
        feature.activate(host.owner)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        guard feature.handle(key, owner: host.owner) == .consumed else { fatalError("voice shortcut passed through") }
        try await settle()
        guard let request = connection.service.requests.first else { fatalError("shortcut did not start recognition") }
        connection.send(VoiceEvent(sessionID: request.sessionID, kind: "recording"))
        connection.send(VoiceEvent(sessionID: request.sessionID, kind: "completed", text: "你好GitHub", transcript: "你好github", processing: processing))
        try await settle()
        guard host.client.document.text == "前文你好GitHub" else { fatalError("final text was not committed to the current input") }
        // Releasing a handled shortcut never leaks into the editor.
        let release = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        precondition(feature.handle(release, owner: host.owner) == .consumed)
        precondition(feature.handle(release, owner: host.owner) == .passThrough)

        // A preparation-stop must wait for actual readiness, then stop exactly once.
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let second = connection.service.requests.last!
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        precondition(connection.service.stopped.isEmpty)
        connection.send(VoiceEvent(sessionID: second.sessionID, kind: "recording"))
        try await settle()
        precondition(connection.service.stopped == [second.sessionID])
        connection.send(VoiceEvent(sessionID: second.sessionID, kind: "recording"))
        try await settle()
        precondition(connection.service.stopped.count == 1)

        // An old result must not commit after deactivation or poison a new session.
        feature.deactivate(host.owner)
        precondition(feature.isIdle)
        feature.activate(host.owner)
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let third = connection.service.requests.last!
        connection.send(VoiceEvent(sessionID: second.sessionID, kind: "completed", text: "旧内容"))
        try await settle()
        precondition(host.client.document.text == "前文你好GitHub")
        host.canCommit = false
        connection.send(VoiceEvent(sessionID: third.sessionID, kind: "completed", text: "焦点外内容"))
        try await settle()
        precondition(host.client.document.text == "前文你好GitHub")
        precondition(feature.isIdle)
        // Cleaning up the session restores the panel, which would hide the message at once: it must come last.
        precondition(host.effects.last == "status:输入位置已变化，语音结果未写入", "rejection message was hidden by the panel restore: \(host.effects)")
        host.canCommit = true

        // Ordinary typing passes through and cancels pending speech.
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let fourth = connection.service.requests.last!
        let ordinary = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        precondition(feature.handle(ordinary, owner: host.owner) == .passThrough)
        precondition(feature.isIdle)
        connection.send(VoiceEvent(sessionID: fourth.sessionID, kind: "completed", text: "取消内容"))
        try await settle()
        precondition(host.client.document.text == "前文你好GitHub")
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let readsBeforeActivation = host.snapshotReads
        feature.activate(InputOwner())
        precondition(host.snapshotReads == readsBeforeActivation, "activation must not synchronously inspect IMK client")
        feature.shutdown()

        // A bare-modifier rewrite shortcut arrives as flagsChanged, where reading NSEvent.isARepeat raises
        // an exception that would abort the input method for every application.
        var modifierSettings = settings
        modifierSettings.rewriteShortcut = "Alt_R"
        let modifierURL = root.appendingPathComponent("modifier-settings.json")
        try JSONEncoder().encode(modifierSettings).write(to: modifierURL)
        let modifierHost = Host()
        let modifierFeature = VoiceFeature(host: modifierHost, settingsURL: modifierURL,
            makeConnection: { Connection(machServiceName: "test.voice.modifier") }, feedback: { _ in }, captureAnchor: { _ in nil })
        modifierFeature.activate(modifierHost.owner)
        let optionDown = CGEvent(source: nil)!
        optionDown.type = .flagsChanged
        optionDown.flags = .maskAlternate
        optionDown.setIntegerValueField(.keyboardEventKeycode, value: 61)
        precondition(modifierFeature.handle(NSEvent(cgEvent: optionDown)!, owner: modifierHost.owner) == .consumed)
        try await settle()
        modifierFeature.shutdown()
        print("PASS VoiceFeature shortcut, commit, preparation-stop, duplicate readiness, stale event, focus rejection, ordinary-key cancellation, bare-modifier rewrite key")
    }
}
