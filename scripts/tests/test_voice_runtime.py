#!/usr/bin/env python3
"""Exercise the public runtime lifecycle with inert capture/model adapters.

No microphone, provider credentials, app build, signing or installation.
"""
from pathlib import Path
import subprocess
import tempfile
from test_voice_lifecycle import voice_dependency_flags

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    dependencies = voice_dependency_flags()
    sources = sorted((ROOT / "Packages/AIMEKit/Sources/AIMEVoice").glob("*.swift"))
    with tempfile.TemporaryDirectory(prefix="aime-voice-runtime-") as directory:
        output = Path(directory)
        run("swiftc", "-swift-version", "6", "-enable-upcoming-feature", "InternalImportsByDefault",
            "-enable-testing", "-parse-as-library", "-emit-library", "-emit-module",
            "-module-name", "AIMEVoice", *dependencies, *sources, "-emit-module-path", output / "AIMEVoice.swiftmodule",
            "-o", output / "libAIMEVoice.dylib")
        run("swiftc", "-swift-version", "6", "-parse-as-library", *voice_dependency_flags(imports_only=True), "-I", output, "-L", output,
            "-lAIMEVoice", "-Xlinker", "-rpath", "-Xlinker", output,
            "scripts/tests/VoiceRuntimeCheck.swift", "-o", output / "runtime-check")
        run(output / "runtime-check")
        run("swiftc", "-swift-version", "6", "-typecheck", *voice_dependency_flags(imports_only=True), "-I", output,
            "Apps/AIMEVoiceService/main.swift")
        print("PASS XPC entry typecheck (not launched)")


if __name__ == "__main__":
    main()
