#!/usr/bin/env python3
"""Public host seam; synthetic IMK/XPC, no recording or credential access."""
from pathlib import Path
import subprocess, tempfile
from test_voice_lifecycle import voice_dependency_flags
ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="aime-feature-") as tmp:
    out = Path(tmp)
    dependencies = voice_dependency_flags()
    for module in ("AIMEVoice", "AIMEVoiceHost"):
        sources = sorted((ROOT / "Packages/AIMEVoiceKit/Sources" / module).glob("*.swift"))
        args = ["swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library", "-emit-module", "-module-name", module, "-emit-module-path", str(out / (module + ".swiftmodule")), "-I", tmp, "-L", tmp]
        if module == "AIMEVoiceHost": args += [*voice_dependency_flags(imports_only=True), "-lAIMEVoice"]
        else: args += dependencies
        subprocess.run(args + list(map(str, sources)) + ["-o", str(out / ("lib" + module + ".dylib"))], cwd=ROOT, check=True)
    for check in ("VoiceFeatureCheck", "VoiceCommitCheck", "VoiceRewriteSelectionCheck"):
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *voice_dependency_flags(imports_only=True), "-I", str(out), "-L", str(out), "-lAIMEVoice", "-lAIMEVoiceHost", "-Xlinker", "-rpath", "-Xlinker", str(out), str(ROOT / f"scripts/tests/{check}.swift"), "-o", str(out / check)], cwd=ROOT, check=True)
        subprocess.run([str(out / check)], cwd=ROOT, check=True)
