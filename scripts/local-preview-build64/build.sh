#!/usr/bin/env bash
# Builds, stages and signs the local Voice Preview from project.local.yml:
#   scripts/local-preview-build64/build.sh BUILD [--install]
# Output: ../dist/Build<BUILD>/AIME Voice Preview.app (outside the repository).
# The installed Preview is the reference for SharedSupport, input source identity and
# designated requirements. --install then replaces it (install.py keeps the old app
# under ../dist/Build<BUILD>/work until the user removes it).
set -euo pipefail

BUILD="${1:?usage: build.sh BUILD [--install]}"
INSTALL="${2:-}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "BUILD must be a number" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/local-preview-build64"
# Without an installed Preview (a new Mac), point AIME_PREVIEW_REFERENCE at a previous dist build.
REFERENCE="${AIME_PREVIEW_REFERENCE:-$HOME/Library/Input Methods/AIME Voice Preview.app}"
OUT="$(cd "$ROOT/.." && pwd)/dist/Build$BUILD"
APP="$OUT/AIME Voice Preview.app"
DERIVED="$ROOT/build/DerivedData"
cd "$ROOT"

[[ -d "$REFERENCE" ]] || { echo "missing reference: $REFERENCE" >&2; exit 1; }
[[ ! -e "$OUT" ]] || { echo "already exists: $OUT" >&2; exit 1; }
[[ -d Packages/AIMEKit/Frameworks/CRime.xcframework ]] || bash scripts/fetch-librime.sh

echo "==> generating project (project.local.yml)"
xcodegen generate --quiet --spec project.local.yml
# One resolved file for both local packages, so Xcode builds the pinned versions.
python3 - "$ROOT" <<'EOF'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
pins = {}
for package in ("AIMEKit", "AIMEVoiceKit"):
    for pin in json.loads((root / "Packages" / package / "Package.resolved").read_text())["pins"]:
        pins.setdefault(pin["identity"], pin)
target = root / "AIME.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps({"pins": sorted(pins.values(), key=lambda pin: pin["identity"]), "version": 2}, indent=2) + "\n")
EOF

echo "==> building apps (Release, build $BUILD)"
xcodebuild -project AIME.xcodeproj -scheme AIME -configuration Release -derivedDataPath "$DERIVED" \
  -onlyUsePackageVersionsFromResolvedFile ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet

echo "==> building CLI"
swift build --build-system native --package-path Packages/AIMEKit -c release --product aime >/dev/null
CLI="$(swift build --build-system native --package-path Packages/AIMEKit -c release --show-bin-path)"

echo "==> staging and signing"
mkdir -p "$OUT" "$ROOT/build"
# Spotlight would register dist/DerivedData apps with LaunchServices as more copies of the input method.
touch "$(dirname "$OUT")/.metadata_never_index" "$ROOT/build/.metadata_never_index"
python3 "$HERE/stage.py" "$ROOT" "$DERIVED/Build/Products/Release" "$REFERENCE" "$APP" "$CLI" --build "$BUILD"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for intermediate in "$DERIVED/Build/Products/Release/AIME.app" "$DERIVED/Build/Products/Release/AIME Settings.app"; do
  [[ -d "$intermediate" ]] && "$LSREG" -u "$intermediate" 2>/dev/null || true
done
# A copied-in source tree or reference keeps Gatekeeper quarantine; macOS will not register a
# quarantined, self-signed input method.
xattr -dr com.apple.quarantine "$APP"
python3 "$HERE/sign-nested.py" "$APP"
python3 "$HERE/sign-local.py" "$APP" "$REFERENCE" "$ROOT"
# Signing scratch next to the app: entitlement files and verified framework duplicates.
rm -rf "$OUT"/*.local.entitlements "$OUT"/framework-layout-*
echo "==> signed $APP"

[[ "$INSTALL" == "--install" ]] || exit 0
mkdir -p "$OUT/work"
swiftc -O "$HERE/input-source.swift" -o "$OUT/work/input-source"
python3 "$HERE/install.py" "$APP" --helper "$OUT/work/input-source" --work "$OUT/work"
"$LSREG" -u "$APP" 2>/dev/null || true
