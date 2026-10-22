#!/usr/bin/env python3
"""No-microphone XPC/recorder lifecycle regression checks (macOS + Swift 6).

Run: python3 scripts/tests/test_voice_lifecycle.py
Builds only AIMEVoice and these isolated checks, never the app or XPC service.
The recorder fixture injects inert capture transports and synthetic CoreMedia
samples: no microphone permission request or live capture occurs.

Sources: FluidVoice CoreAudioCaptureSupport (GPL-3.0), AIME recorder lifecycle,
CMSampleBufferCopyPCMDataIntoAudioBufferList, and xpc_transaction_begin/end.
SwiftPM prepares native/model-library dependencies; no model weights are fetched.

This validates lifecycle behavior, NOT microphone startup speed or Bluetooth
hardware behavior. Those need user recording and the metadata-only latency logs.
"""
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


_dependency_flags = None


def voice_dependency_flags(*, imports_only=False):
    """Use SwiftPM's actual dependency graph for the standalone Swift checks."""
    global _dependency_flags
    if _dependency_flags is not None:
        return list(_dependency_flags[0 if imports_only else 1])
    package = ROOT / "Packages/AIMEVoiceKit"
    scratch = package / ".build/voice-contracts"
    # Standalone checks consume native SwiftPM's Modules/*.build layout.
    run("swift", "build", "--build-system", "native", "--package-path", package, "--scratch-path", scratch,
        "--target", "AIMEVoice", "-Xswiftc", "-enable-testing")
    output = Path(subprocess.check_output(
        ["swift", "build", "--build-system", "native", "--package-path", str(package), "--scratch-path", str(scratch), "--show-bin-path"],
        cwd=ROOT, text=True).strip())
    flags = ["-I", str(output / "Modules")]
    description = json.loads((output / "description.json").read_text())
    voice = next(command for command in description["swiftCommands"].values()
                 if command.get("moduleName") == "AIMEVoice")
    # Include source-provided C module maps as well as generated build products.
    for argument in voice["otherArguments"]:
        if argument.startswith("-fmodule-map-file="):
            flags += ["-Xcc", argument]
    imports = list(flags)
    for directory in sorted(output.glob("*.build")):
        if directory.name not in {"AIMEVoice.build", "AIMEVoiceHost.build", "AIMEVoiceSettings.build"}:
            flags += [str(path) for path in sorted(directory.rglob("*.o"))]
    artifacts = scratch / "artifacts"
    matched = False
    for framework in artifacts.rglob("TranscribeCpp.xcframework"):
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        for library in info["AvailableLibraries"]:
            if library["SupportedPlatform"] != "macos":
                continue
            path = framework / library["LibraryIdentifier"] / library["LibraryPath"]
            headers = library.get("HeadersPath")
            if headers:
                flags += ["-I", str(path.parent / headers)]
                imports += ["-I", str(path.parent / headers)]
            if path.suffix == ".framework":
                flags += ["-F", str(path.parent), "-framework", path.stem,
                          "-Xlinker", "-rpath", "-Xlinker", str(path.parent)]
                imports += ["-F", str(path.parent)]
            else:
                flags += [str(path)]
            matched = True
            break
    if not matched:
        raise RuntimeError("SwiftPM did not provide the macOS TranscribeCpp binary")
    flags += ["-lc++", "-lz", "-framework", "Accelerate", "-framework", "Foundation",
              "-framework", "Metal", "-framework", "MetalKit", "-framework", "CoreAudio"]
    _dependency_flags = (imports, flags)
    return list(imports if imports_only else flags)


def main():
    dependencies = voice_dependency_flags()
    sources = sorted((ROOT / "Packages/AIMEVoiceKit/Sources/AIMEVoice").glob("*.swift"))
    if len(sys.argv) == 3 and sys.argv[1] == "--compile-routing":
        run("swiftc", "-swift-version", "6", "-parse-as-library", *dependencies, *sources,
            "scripts/tests/VoiceRoutingCheck.swift", "-o", sys.argv[2])
        return
    if len(sys.argv) == 4 and sys.argv[1] == "--compile-check":
        run("swiftc", "-swift-version", "6", "-parse-as-library", *dependencies, *sources,
            sys.argv[2], "-o", sys.argv[3])
        return
    with tempfile.TemporaryDirectory(prefix="aime-voice-lifecycle-") as directory:
        output = Path(directory)
        run("swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library", "-emit-module",
            "-module-name", "AIMEVoice", *dependencies, *sources, "-emit-module-path", output / "AIMEVoice.swiftmodule",
            "-o", output / "libAIMEVoice.dylib")
        run("swiftc", "-swift-version", "6", "-parse-as-library", *voice_dependency_flags(imports_only=True), "-I", output, "-L", output,
            "-lAIMEVoice", "-Xlinker", "-rpath", "-Xlinker", output,
            "Packages/AIMEVoiceKit/Sources/AIMEVoiceHost/VoiceServiceBridge.swift", "scripts/tests/VoiceBridgeLifecycleCheck.swift",
            "-o", output / "bridge-check")
        run(output / "bridge-check")
        run("swiftc", "-swift-version", "6", "-parse-as-library", *dependencies,
            "Packages/AIMEVoiceKit/Sources/AIMEVoice/VoiceRecorder.swift",
            "Packages/AIMEVoiceKit/Sources/AIMEVoice/FluidVoiceCapture.swift",
            "scripts/tests/VoiceRecorderLifecycleCheck.swift", "-o", output / "recorder-check")
        run(output / "recorder-check")
        run("swiftc", "-swift-version", "6", "-typecheck", *voice_dependency_flags(imports_only=True), "-I", output,
            "Local/AIMEVoiceService/main.swift")
        print("PASS service interface typecheck (not launched)")


if __name__ == "__main__":
    main()
