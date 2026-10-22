#!/bin/sh
# Local customization contract, checked after every upstream merge:
#   1. upstream files differ from the merged upstream commit only in the allowed hook files;
#   2. local files inside upstream directories stay in the allowed local paths;
#   3. every hook and local module is still in place.
# --build also compiles both packages, runs the local and subscription tests, and
# builds the local Xcode project unsigned (Debug).
set -eu
cd "$(dirname "$0")/.."

fail() {
  echo "local seam: $1" >&2
  exit 1
}

# Upstream files the local branch may change: one-line hooks only (docs/upstream-merge.md).
ALLOWED_UPSTREAM='
Apps/AIME/AIMEInputController.swift
Apps/AIME/AppDelegate.swift
Apps/AIME/InputEngine.swift
Apps/AIMESettings/Model/DeployService.swift
Apps/AIMESettings/Model/SettingsModel.swift
Apps/AIMESettings/Views/OverviewView.swift
Apps/AIMESettings/Views/RootView.swift
Packages/AIMEKit/Sources/AIMECore/AIMEPaths.swift
Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift
'
# Local files that must live inside upstream directories (compiled into upstream targets).
ALLOWED_LOCAL_IN_UPSTREAM='^Packages/AIMEKit/Sources/AIMECore/LocalCustomization/|^Packages/AIMEKit/Tests/AIMECoreTests/LocalVocabularyCustomizationTests\.swift$'

# During a merge the incoming upstream commit is the reference.
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  BASE=MERGE_HEAD
else
  BASE=$(git merge-base HEAD origin/main)
fi

upstream_files=$(mktemp)
changed_files=$(mktemp)
added_files=$(mktemp)
trap 'rm -f "$upstream_files" "$changed_files" "$added_files"' EXIT
git ls-tree -r --name-only "$BASE" >"$upstream_files"
# --no-renames: a renamed or moved upstream file must show up under its upstream path (as a
# deletion) and its new path (as an addition), not only under the new path.
git diff --no-renames --name-only "$BASE" -- >"$changed_files"
{
  git diff --no-renames --name-only --diff-filter=A "$BASE" -- Apps Packages/AIMEKit
  git ls-files --others --exclude-standard -- Apps Packages/AIMEKit
} >"$added_files"

# Read line by line so paths with spaces are not split into words.
while IFS= read -r file; do
  if grep -Fqx -- "$file" "$upstream_files"; then
    printf '%s\n' "$ALLOWED_UPSTREAM" | grep -Fqx -- "$file" || fail "upstream file changed outside the hook list: $file"
  fi
done <"$changed_files"
while IFS= read -r file; do
  printf '%s\n' "$file" | grep -Eq "$ALLOWED_LOCAL_IN_UPSTREAM" || fail "local file inside an upstream directory: $file (move it under Local/)"
done <"$added_files"

require_file() {
  [ -f "$1" ] || fail "missing $1"
}

require_text() {
  require_file "$1"
  grep -F -q -- "$2" "$1" || fail "$1 does not contain: $2"
}

require_file Packages/AIMEVoiceKit/Package.swift
require_file Packages/AIMEVoiceKit/Sources/AIMEVoice/VoiceProcessor.swift
require_file Packages/AIMEVoiceKit/Sources/AIMEVoiceHost/VoiceFeature.swift
require_file Packages/AIMEVoiceKit/Sources/AIMEVoiceSettings/VoiceSettingsPane.swift
require_file Packages/AIMEKit/Sources/AIMECore/LocalCustomization/LocalBuildInfo.swift
require_file Packages/AIMEKit/Sources/AIMECore/LocalCustomization/LocalVocabularyCustomization.swift
require_file Local/AIME/LocalVoiceAdapter.swift
require_file Local/AIMESettings/LocalIntegrationControls.swift
require_file Local/AIMEVoiceService/Info.plist
require_text project.local.yml '  - project.yml'
require_text project.local.yml 'product: AIMEVoiceHost'
require_text project.local.yml 'product: AIMEVoiceSettings'

require_text Apps/AIME/AIMEInputController.swift 'import AIMEVoiceHost'
require_text Apps/AIME/AIMEInputController.swift 'let voiceOwner = InputOwner()'
require_text Apps/AIME/AIMEInputController.swift 'engine.voiceFeature.activate(voiceOwner)'
require_text Apps/AIME/AIMEInputController.swift 'engine.voiceFeature.deactivate(this.voiceOwner)'
require_text Apps/AIME/AIMEInputController.swift '.keyUp'
require_text Apps/AIME/AIMEInputController.swift 'engine.voiceFeature.handle(event, owner: voiceOwner)'
require_text Apps/AIME/InputEngine.swift 'import AIMEVoiceHost'
require_text Apps/AIME/InputEngine.swift 'lazy var voiceFeature'
require_text Apps/AIME/InputEngine.swift '_ = voiceFeature'
require_text Apps/AIME/AppDelegate.swift 'voiceFeature.shutdown()'
require_text Apps/AIMESettings/Views/RootView.swift 'case .voice: VoiceSettingsPane'
require_text Apps/AIMESettings/Views/OverviewView.swift 'LocalIntegrationControls.replacesUpdater'
require_text Apps/AIMESettings/Model/DeployService.swift 'LocalBuildInfo.inputMethodBundleID'
require_text Apps/AIMESettings/Model/SettingsModel.swift 'LocalBuildInfo.inputModeID'
require_text Packages/AIMEKit/Sources/AIMECore/AIMEPaths.swift 'LocalBuildInfo.dataFolderName'
require_text Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift 'LocalVocabularyCustomization.afterRebuild'
require_text Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift 'LocalVocabularyCustomization.signaturePart'

if [ "${1:-}" = "--build" ]; then
  swift build --package-path Packages/AIMEVoiceKit
  swift test --package-path Packages/AIMEKit --filter 'LocalVocabularyCustomizationTests|SubscriptionTests'
  xcodegen generate --quiet --spec project.local.yml
  xcodebuild -project AIME.xcodeproj -scheme AIME -configuration Debug -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO build -quiet
fi

echo "local seam: ok"
