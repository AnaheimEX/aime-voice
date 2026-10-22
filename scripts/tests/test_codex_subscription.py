#!/usr/bin/env python3
"""Offline ChatGPT protocol regression. Compiles only the client and its dedicated mock test."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Packages/AIMEVoiceKit/Sources/AIMEVoice"
with tempfile.TemporaryDirectory(prefix="aime-codex-protocol-") as temp:
    executable = pathlib.Path(temp) / "check"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library",
        str(SOURCES / "CodexSubscriptionClient.swift"),
        str(SOURCES / "CodexResponsesStream.swift"),
        str(SOURCES / "CodexIDTokenVerification.swift"),
        str(SOURCES / "CodexOAuthCallbackListener.swift"),
        str(ROOT / "scripts/tests/CodexSubscriptionCheck.swift"),
        "-o", str(executable),
    ], check=True, cwd=ROOT)
    subprocess.run([str(executable)], check=True, timeout=30, cwd=ROOT)
