import AIMEVoiceHost
import Foundation
import InputMethodKit

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

@main
struct VoiceCommitCheck {
    @MainActor static func main() throws {
        let ordinaryDocument = Document()
        let ordinaryClient = Client(ordinaryDocument)
        ordinaryClient.generatesIdentifier = true
        let ordinaryTarget = VoiceCommitTarget(client: ordinaryClient)
        let ordinaryRejection = ordinaryTarget.insert("语音", into: ordinaryClient)
        guard ordinaryRejection == nil, ordinaryDocument.text == "前文语音" else {
            throw NSError(domain: "VoiceCommitCheck", code: 30, userInfo: [NSLocalizedDescriptionKey: "Build 30 regression: unchanged native client rejected after identifier generation: \(String(describing: ordinaryRejection))"])
        }
        print("PASS unchanged native client inserts despite generated identifiers")

        let doc = Document()
        let first = Client(doc)
        let target = VoiceCommitTarget(client: first)
        let refreshed = Client(doc)
        let rejection = target.insert("语音", into: refreshed)
        guard rejection == .clientChanged, doc.text == "前文" else {
            throw NSError(domain: "VoiceCommitCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "matching identifier strings must not authorize a different client"])
        }
        print("PASS matching identifier strings do not authorize a different client")

        let limitedDocument = Document()
        let limitedClient = Client(limitedDocument)
        limitedClient.currentSelectionOnly = true
        let limitedTarget = VoiceCommitTarget(client: limitedClient)
        let limitedRejection = limitedTarget.insert("语音", into: limitedClient)
        guard limitedRejection == nil, limitedDocument.text == "前文语音" else {
            throw NSError(domain: "VoiceCommitCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "native insert returned without inserting into the current selection"])
        }
        print("PASS current-selection-only client receives dictation")

        let switchedDocument = Document()
        let reusedProxy = Client(switchedDocument)
        let switchedTarget = VoiceCommitTarget(client: reusedProxy)
        let differentField = Client(switchedDocument, id: "field-b")
        guard switchedTarget.insert("不能写入", into: differentField) == .clientChanged,
              switchedDocument.text == "前文" else {
            throw NSError(domain: "VoiceCommitCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "another field with identical surrounding text must not receive stale dictation"])
        }
        print("PASS different field cannot receive stale dictation")

        for scenario in ["application", "selection", "context", "empty"] {
            let document = Document()
            let client = Client(document)
            let target = VoiceCommitTarget(client: client)
            let expected: VoiceCommitTarget.Rejection
            switch scenario {
            case "application": client.application = "app.other.editor"; expected = .clientChanged
            case "selection": document.selection.location = 0; expected = .selectionChanged
            case "context": document.text = "改过"; expected = .contextChanged
            default: expected = .emptyResult
            }
            let rejection = target.insert(scenario == "empty" ? "  " : "不能写入", into: client)
            guard rejection == expected, document.text == (scenario == "context" ? "改过" : "前文") else {
                throw NSError(domain: "VoiceCommitCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "dictation guard failed: \(scenario)"])
            }
            print("PASS rejects \(scenario) change without inserting")
        }

        let selectedDocument = Document()
        selectedDocument.selection = NSRange(location: 0, length: 2)
        let selectedClient = Client(selectedDocument)
        selectedClient.currentSelectionOnly = true
        guard VoiceCommitTarget(client: selectedClient).insert("语音", into: selectedClient) == nil,
              selectedDocument.text == "语音" else { throw NSError(domain: "VoiceCommitCheck", code: 5) }
        print("PASS replaces an unchanged selection exactly once")

        for refresh in [false, true] {
            let document = Document()
            let initial = Client(document, id: "")
            let target = VoiceCommitTarget(client: initial)
            let current = refresh ? Client(document, id: "") : initial
            let rejection = target.insert("语音", into: current)
            guard rejection == (refresh ? .clientChanged : nil),
                  document.text == (refresh ? "前文" : "前文语音") else {
                throw NSError(domain: "VoiceCommitCheck", code: 6)
            }
        }
        print("PASS missing client IDs preserve strict proxy checks")
        print("PASS 11 native commit scenarios")
    }
}
