#!/bin/sh
# Confirm the branch-owned voice module and its input-method seam survived a merge.
set -eu
cd "$(dirname "$0")/.."

fail() {
  echo "voice seam: $1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing $1"
}

require_text() {
  file=$1
  text=$2
  require_file "$file"
  grep -F -q -- "$text" "$file" || fail "$file does not contain: $text"
}

require_file Packages/AIMEKit/Sources/AIMEVoice/VoiceProcessor.swift
require_file Packages/AIMEKit/Sources/AIMEVoiceHost/VoiceFeature.swift
require_file Packages/AIMEKit/Sources/AIMEVoiceSettings/VoiceSettingsPane.swift
require_file Apps/AIMEVoiceService/Info.plist
require_file Apps/AIME/LocalVoiceAdapter.swift

require_text Packages/AIMEKit/Package.swift '.library(name: "AIMEVoice"'
require_text Packages/AIMEKit/Package.swift '.library(name: "AIMEVoiceHost"'
require_text Packages/AIMEKit/Package.swift '.library(name: "AIMEVoiceSettings"'
require_text project.yml 'AIME Voice:'
require_text project.yml 'product: AIMEVoiceHost'
require_text project.yml 'product: AIMEVoiceSettings'
require_text Apps/AIMESettings/Views/RootView.swift 'case .voice: "语音输入"'

require_text Apps/AIME/AIMEInputController.swift 'import AIMEVoiceHost'
require_text Apps/AIME/AIMEInputController.swift 'let voiceOwner = InputOwner()'
require_text Apps/AIME/AIMEInputController.swift 'engine.voiceFeature.activate(voiceOwner)'
require_text Apps/AIME/AIMEInputController.swift 'engine.voiceFeature.deactivate(this.voiceOwner)'
require_text Apps/AIME/AIMEInputController.swift '.keyUp'
require_text Apps/AIME/AIMEInputController.swift 'engine.voiceFeature.handle(event, owner: voiceOwner)'

require_text Apps/AIME/InputEngine.swift 'import AIMEVoiceHost'
require_text Apps/AIME/InputEngine.swift 'lazy var voiceFeature'
require_text Apps/AIME/InputEngine.swift 'showStatus(_ text: String, persistent: Bool = false)'

echo "voice seam: ok"
