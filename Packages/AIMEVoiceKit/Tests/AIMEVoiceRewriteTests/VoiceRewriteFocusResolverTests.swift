import AppKit
import InputMethodKit
import XCTest
@testable import AIMEVoiceHost

final class VoiceRewriteFocusResolverTests: XCTestCase {
    func testPlainAndAttributedValuesAreFieldText() {
        XCTAssertEqual(VoiceRewriteFocusText.string(from: "把海报发给我"), "把海报发给我")
        let attributed = NSAttributedString(string: "备忘录正文", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        XCTAssertEqual(VoiceRewriteFocusText.string(from: attributed), "备忘录正文")
        XCTAssertNil(VoiceRewriteFocusText.string(from: NSNumber(value: 3)))
        XCTAssertNil(VoiceRewriteFocusText.string(from: nil as String?))
    }

    func testNavigationStopsOnEditorsAndSecureControlsAndClimbsPastRuns() {
        XCTAssertEqual(VoiceRewriteFocusPolicy.navigation(role: "AXTextArea", subrole: ""), .useAsField)
        XCTAssertEqual(VoiceRewriteFocusPolicy.navigation(role: "AXTextField", subrole: ""), .useAsField)
        XCTAssertEqual(VoiceRewriteFocusPolicy.navigation(role: "AXWindow", subrole: ""), .searchInside)
        XCTAssertEqual(VoiceRewriteFocusPolicy.navigation(role: "AXScrollArea", subrole: ""), .searchInside)
        XCTAssertEqual(VoiceRewriteFocusPolicy.navigation(role: "AXStaticText", subrole: ""), .climb)
        XCTAssertEqual(VoiceRewriteFocusPolicy.navigation(role: "AXTextField", subrole: "AXSecureTextField"), .stopSecure)
    }

    func testBundlePathMustBeNestedNotJustAPrefix() {
        XCTAssertTrue(VoiceRewriteFocusPolicy.pathIsInsideAppBundle(
            "/Applications/TextEdit.app/Contents/MacOS/TextEdit", appBundle: "/Applications/TextEdit.app"))
        XCTAssertFalse(VoiceRewriteFocusPolicy.pathIsInsideAppBundle(
            "/Applications/TextEdit.app-evil/Contents/MacOS/TextEdit", appBundle: "/Applications/TextEdit.app"))
    }

    func testApplicationTextAreaResolvesWhenSystemWideFocusIsMissing() {
        let editor = textNode("editor", pid: 10, role: "AXTextArea", value: "把海报发给我",
            selection: NSRange(location: 6, length: 0))
        let choice = VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: editor))
        XCTAssertEqual(choice?.value, "把海报发给我")
        XCTAssertEqual(choice?.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(choice?.processID, Optional(Int32(10)))
        XCTAssertEqual(choice?.selection, Optional(NSRange(location: 6, length: 0)))
        XCTAssertEqual(choice?.isEditable, Optional(true))
        XCTAssertEqual(choice?.isSecure, Optional(false))
        XCTAssertEqual(choice?.singleLine, Optional(false))
    }

    func testWindowWithOneNestedTextAreaIsTheEditorAfterDictation() {
        let editor = textNode("editor", pid: 10, role: "AXTextArea", value: "刚听写的句子")
        let scroll = VoiceRewriteFocusResolver.Node(token: "scroll", processID: 10, role: "AXScrollArea", children: [editor])
        let window = VoiceRewriteFocusResolver.Node(token: "window", processID: 10, role: "AXWindow", children: [scroll])
        let choice = VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: window))
        XCTAssertEqual(choice?.token, "editor")
        XCTAssertEqual(choice?.value, "刚听写的句子")
    }

    func testSingleLineFieldIsMarkedAndSearchFieldCounts() {
        let field = textNode("field", pid: 10, role: "AXTextField", value: "标题")
        XCTAssertEqual(VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: field))?.singleLine, Optional(true))
        let search = textNode("search", pid: 10, role: "AXSearchField", value: "查询")
        XCTAssertEqual(VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: search))?.singleLine, Optional(true))
    }

    func testTwoEditorsWithoutFocusAreNotGuessed() {
        let window = VoiceRewriteFocusResolver.Node(token: "window", processID: 10, role: "AXWindow", children: [
            textNode("to", pid: 10, role: "AXTextField", value: "收件人"),
            textNode("body", pid: 10, role: "AXTextArea", value: "正文"),
        ])
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: window)))
    }

    func testFocusedEditorWinsAmongSeveral() {
        var body = textNode("body", pid: 10, role: "AXTextArea", value: "正文")
        body.focused = true
        let window = VoiceRewriteFocusResolver.Node(token: "window", processID: 10, role: "AXWindow", children: [
            textNode("to", pid: 10, role: "AXTextField", value: "收件人"),
            body,
        ])
        XCTAssertEqual(VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: window))?.token, "body")
    }

    func testIncompleteChildListDoesNotAssumeTheOnlyLoadedEditor() {
        var window = VoiceRewriteFocusResolver.Node(token: "window", processID: 10, role: "AXWindow", children: [
            textNode("body", pid: 10, role: "AXTextArea", value: "正文"),
        ])
        window.childrenComplete = false
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: window)))
    }

    func testClientAppBeatsADifferentFrontmostApp() {
        let clientEditor = textNode("client", pid: 10, role: "AXTextArea", value: "甲")
        let frontEditor = textNode("front", pid: 20, role: "AXTextArea", value: "乙")
        var probe = probe(frontmost: VoiceRewriteFocusResolver.App(processID: 20, bundleID: "com.google.Chrome", bundlePath: nil), application: frontEditor)
        probe.clientApplication = textEdit
        probe.applicationFocused[10] = clientEditor
        XCTAssertEqual(VoiceRewriteFocusResolver.resolve(probe)?.value, "甲")
        XCTAssertEqual(VoiceRewriteFocusResolver.resolve(probe)?.bundleID, "com.apple.TextEdit")
    }

    func testUnresolvedClientDoesNotFallThroughToAnotherApp() {
        var probe = probe(frontmost: textEdit, application: textNode("editor", pid: 10, role: "AXTextArea", value: "甲"))
        probe.clientBundleUnresolved = true
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe))
    }

    func testSystemWideElementFromAnotherProcessIsIgnored() {
        var probe = VoiceRewriteFocusResolver.Probe(selfProcessID: 1, frontmost: textEdit)
        probe.systemFocused = textNode("other", pid: 99, role: "AXTextArea", value: "别的应用")
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe))
    }

    func testHelperProcessUnderTheTargetKeepsTheTargetBundleID() {
        let helper = textNode("helper", pid: 42, role: "AXTextArea", value: "网页输入")
        var probe = probe(frontmost: VoiceRewriteFocusResolver.App(processID: 10, bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app"), application: helper)
        probe.processes[42] = VoiceRewriteFocusResolver.Process(processID: 42, parentProcessID: 10, bundlePath: nil)
        let choice = VoiceRewriteFocusResolver.resolve(probe)
        XCTAssertEqual(choice?.value, "网页输入")
        XCTAssertEqual(choice?.processID, Optional(Int32(42)))
        XCTAssertEqual(choice?.bundleID, "com.apple.Safari")
    }

    func testHelperNestedInTheAppBundleIsAccepted() {
        let helper = textNode("helper", pid: 42, role: "AXTextArea", value: "编辑器")
        var probe = probe(frontmost: VoiceRewriteFocusResolver.App(processID: 10, bundleID: "com.microsoft.VSCode",
            bundlePath: "/Applications/Visual Studio Code.app"), application: helper)
        probe.processes[42] = VoiceRewriteFocusResolver.Process(processID: 42, parentProcessID: nil,
            bundlePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app")
        XCTAssertEqual(VoiceRewriteFocusResolver.resolve(probe)?.bundleID, "com.microsoft.VSCode")
    }

    func testProcessParentedOnTheInputMethodIsRejected() {
        let helper = textNode("helper", pid: 42, role: "AXTextArea", value: "不是目标")
        var probe = probe(frontmost: textEdit, application: helper)
        probe.selfProcessID = 7
        probe.processes[42] = VoiceRewriteFocusResolver.Process(processID: 42, parentProcessID: 7, bundlePath: nil)
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe))
    }

    func testInputMethodBundleIsNotATarget() {
        let probe = VoiceRewriteFocusResolver.Probe(selfProcessID: 7, selfBundleID: "app.zool.inputmethod.aime",
            frontmost: VoiceRewriteFocusResolver.App(processID: 7, bundleID: "app.zool.inputmethod.aime", bundlePath: nil),
            applicationFocused: [7: textNode("self", pid: 7, role: "AXTextArea", value: "输入法自己")])
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe))
    }

    func testSecureEventInputAndUntrustedReadsFailClosed() {
        let editor = textNode("editor", pid: 10, role: "AXTextArea", value: "正文")
        var secureInput = probe(frontmost: textEdit, application: editor)
        secureInput.secureEventInput = true
        var untrusted = probe(frontmost: textEdit, application: editor)
        untrusted.trusted = false
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(secureInput))
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(untrusted))
    }

    func testPasswordValueIsNeverCopied() {
        let secure = VoiceRewriteFocusResolver.Node(token: "password", processID: 10, role: "AXTextField",
            subrole: "AXSecureTextField", value: .text("secret-password"), focused: true)
        let choice = VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: secure))
        XCTAssertEqual(choice?.isSecure, Optional(true))
        XCTAssertEqual(choice?.isEditable, Optional(false))
        XCTAssertEqual(choice?.value, "")
    }

    func testFocusedEditorBeatsASecureSiblingWithoutReadingIt() {
        var body = textNode("body", pid: 10, role: "AXTextArea", value: "正文")
        body.focused = true
        let secure = VoiceRewriteFocusResolver.Node(token: "password", processID: 10, role: "AXTextField",
            subrole: "AXSecureTextField", value: .text("secret-password"), focused: false)
        let window = VoiceRewriteFocusResolver.Node(token: "window", processID: 10, role: "AXWindow", children: [secure, body])
        let choice = VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: window))
        XCTAssertEqual(choice?.token, "body")
        XCTAssertEqual(choice?.value, "正文")
        XCTAssertEqual(choice?.isSecure, Optional(false))
    }

    func testStaticTextIsNotAnEditor() {
        let label = VoiceRewriteFocusResolver.Node(token: "label", processID: 10, role: "AXStaticText", value: .text("标签"))
        XCTAssertNil(VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: label)))
    }

    func testCustomControlWithSettableTextIsAnEditor() {
        var custom = VoiceRewriteFocusResolver.Node(token: "custom", processID: 10, role: "AXGroup", value: .text("自定义编辑器"))
        custom.selectedRangeSettable = true
        let choice = VoiceRewriteFocusResolver.resolve(probe(frontmost: textEdit, application: custom))
        XCTAssertEqual(choice?.value, "自定义编辑器")
        XCTAssertEqual(choice?.isEditable, Optional(true))
    }

    private let textEdit = VoiceRewriteFocusResolver.App(processID: 10, bundleID: "com.apple.TextEdit", bundlePath: "/System/Applications/TextEdit.app")

    private func textNode(_ token: String, pid: Int32, role: String, value: String, selection: NSRange? = nil) -> VoiceRewriteFocusResolver.Node {
        VoiceRewriteFocusResolver.Node(token: token, processID: pid, role: role, value: .text(value), selection: selection)
    }

    private func probe(frontmost: VoiceRewriteFocusResolver.App, application: VoiceRewriteFocusResolver.Node) -> VoiceRewriteFocusResolver.Probe {
        VoiceRewriteFocusResolver.Probe(selfProcessID: 1, frontmost: frontmost, applicationFocused: [frontmost.processID: application])
    }
}

@MainActor
final class VoiceRewriteFocusMessageTests: XCTestCase {
    func testResolvedFieldIsNotReportedAsMissing() {
        let ax = RoutingAccessibility()
        ax.matched = VoiceRewriteFieldSnapshot(element: NSObject(), processID: 10, bundleID: "com.apple.TextEdit",
            value: "把海报发给我", selection: NSRange(location: 6, length: 0))
        let message = VoiceRewriteSelection.preparationFailureMessage(client: FocusClient(), origin: nil, accessibility: ax)
        XCTAssertFalse(message.contains("无法读取当前输入框"))
        XCTAssertTrue(message.contains("没有已验证的最近听写内容"))
    }

    func testMissingFieldKeepsTheRefocusMessage() {
        let message = VoiceRewriteSelection.preparationFailureMessage(client: FocusClient(), origin: nil, accessibility: RoutingAccessibility())
        XCTAssertEqual(message, "无法读取当前输入框，请重新聚焦后重试或手动选中文字")
    }

    func testSecureSnapshotIsProtectedRatherThanMissing() {
        let ax = RoutingAccessibility()
        ax.matched = VoiceRewriteFieldSnapshot(element: NSObject(), processID: 10, bundleID: "com.apple.TextEdit",
            value: "", selection: nil, isEditable: false, isSecure: true, selectedTextSettable: false, valueSettable: false)
        let message = VoiceRewriteSelection.preparationFailureMessage(client: FocusClient(), origin: nil, accessibility: ax)
        XCTAssertEqual(message, "当前输入框不可编辑或受保护，未改写")
    }
}

@MainActor
private final class RoutingAccessibility: VoiceRewriteAccessibility {
    var isTrusted = true
    var matched: VoiceRewriteFieldSnapshot?
    func focusedField() -> VoiceRewriteFieldSnapshot? { nil }
    func focusedField(matching client: (any IMKTextInput)?) -> VoiceRewriteFieldSnapshot? { matched }
    func select(_ range: NSRange, in field: VoiceRewriteFieldSnapshot) -> Bool { false }
    func replaceSelectedText(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool { false }
    func replaceValue(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool { false }
}

private final class FocusClient: NSObject, IMKTextInput {
    func insertText(_ value: Any!, replacementRange: NSRange) {}
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func uniqueClientIdentifierString() -> String! { "field" }
    func bundleIdentifier() -> String! { "com.apple.TextEdit" }
    func setMarkedText(_ value: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func length() -> Int { 0 }
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
