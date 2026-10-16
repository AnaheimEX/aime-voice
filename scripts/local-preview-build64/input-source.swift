import Carbon
import Foundation

func identifier(_ source: TISInputSource) -> String {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String ?? ""
}
func source(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
}
let arguments = CommandLine.arguments
switch arguments[1] {
case "current":
    print(identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
case "select":
    guard let item = source(arguments[2]) else { exit(2) }
    exit(TISSelectInputSource(item) == noErr ? 0 : 3)
case "register":
    let url = URL(fileURLWithPath: arguments[2])
    guard TISRegisterInputSource(url as CFURL) == noErr else { exit(4) }
    guard let item = source("app.zool.inputmethod.aime.voicepreview.hans") else { exit(5) }
    exit(TISEnableInputSource(item) == noErr ? 0 : 6)
default: exit(1)
}
