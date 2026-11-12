#!/usr/bin/env bash
# Builds, stages, signs and installs AIME.app (with the local voice module) from project.local.yml:
#   scripts/local-preview-build64/build.sh [BUILD] [--install]
# Preserves upstream's exact bundle identifiers (app.zool.inputmethod.aime) and replaces
# ~/Library/Input Methods/AIME.app directly in place without leaving duplicate apps or backups.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/local-preview-build64"
INSTALLED="$HOME/Library/Input Methods/AIME.app"

BUILD=""
INSTALL=""
for arg in "$@"; do
  if [[ "$arg" == "--install" ]]; then
    INSTALL="--install"
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    BUILD="$arg"
  else
    echo "usage: build.sh [BUILD] [--install]" >&2
    exit 1
  fi
done

if [[ -z "$BUILD" ]]; then
  if [[ -f "$INSTALLED/Contents/Info.plist" ]]; then
    OLD_BUILD=$(defaults read "$INSTALLED/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "30")
    BUILD=$((OLD_BUILD + 1))
  else
    BUILD=31
  fi
fi

OUT="$(cd "$ROOT/.." && pwd)/dist/Build$BUILD"
APP="$OUT/AIME.app"
DERIVED="$ROOT/build/DerivedData"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cd "$ROOT"

rm -rf "$OUT"
[[ -d Packages/AIMEKit/Frameworks/CRime.xcframework ]] || bash scripts/fetch-librime.sh
[[ -f build/SharedSupport/default.yaml ]] || bash scripts/fetch-dicts.sh
ditto SharedSupport build/SharedSupport
/usr/bin/python3 scripts/dictionary-metadata.py --shared-dir build/SharedSupport

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
mkdir -p "$ROOT/build"
touch "$ROOT/build/.metadata_never_index"
xcodebuild -project AIME.xcodeproj -scheme AIME -configuration Release -derivedDataPath "$DERIVED" \
  -onlyUsePackageVersionsFromResolvedFile ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet

echo "==> building CLI"
swift build --build-system native --package-path Packages/AIMEKit -c release --product aime >/dev/null
CLI="$(swift build --build-system native --package-path Packages/AIMEKit -c release --show-bin-path)"

echo "==> staging and signing"
mkdir -p "$OUT"
touch "$(dirname "$OUT")/.metadata_never_index"
python3 "$HERE/stage.py" "$ROOT" "$DERIVED/Build/Products/Release" "$APP" "$CLI" --build "$BUILD"
# Unregister and remove intermediate Xcode build bundles immediately so LaunchServices never indexes them.
for intermediate in "$DERIVED/Build/Products/Release/AIME.app/Contents/Applications/AIME Settings.app" \
                    "$DERIVED/Build/Products/Release/AIME.app" \
                    "$DERIVED/Build/Products/Release/AIME Settings.app" \
                    "$DERIVED/Build/Products/Debug/AIME.app/Contents/Applications/AIME Settings.app" \
                    "$DERIVED/Build/Products/Debug/AIME.app" \
                    "$DERIVED/Build/Products/Debug/AIME Settings.app"; do
  if [[ -d "$intermediate" ]]; then
    "$LSREG" -u "$intermediate" 2>/dev/null || true
    rm -rf "$intermediate"
  fi
done

xattr -dr com.apple.quarantine "$APP"
python3 "$HERE/sign-nested.py" "$APP"
python3 "$HERE/sign-local.py" "$APP" "$ROOT"
rm -rf "$OUT"/*.local.entitlements "$OUT"/framework-layout-*
echo "==> signed $APP"

if [[ "$INSTALL" != "--install" ]]; then
  exit 0
fi

mkdir -p "$OUT/work"
swiftc -O "$HERE/input-source.swift" -o "$OUT/work/input-source"
python3 "$HERE/install.py" "$APP" --helper "$OUT/work/input-source" --work "$OUT/work"
rm -rf "$(dirname "$OUT")"/Build*
