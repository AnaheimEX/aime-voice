#!/usr/bin/env python3
"""Loopback provider contract checks. Synthetic credentials only."""
import json
from test_voice_lifecycle import voice_dependency_flags
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
errors = []
seen = []
seen_http = []
connections = []
redirect_hits = []
cancel_ready = threading.Event()
cancel_closed = threading.Event()


class RedirectTarget(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        redirect_hits.append(self.path)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path in ("/v1/warm", "/v1/anonymous", "/v1/redirect", "/v1/cancel", "/v1/cancel-state", "/v1/trickle"):
            seen_http.append(self.path)
            expected_key = {
                "/v1/warm": "Bearer synthetic-other-key",
                "/v1/anonymous": None,
            }.get(self.path, "Bearer synthetic-metrics-key")
            self.check_isolation(expected_key)
            if self.path == "/v1/trickle":
                self.send_response(200); self.send_header("Content-Length", "22"); self.end_headers()
                try:
                    for _ in range(20):
                        self.wfile.write(b" "); self.wfile.flush(); time.sleep(0.04)
                    self.wfile.write(b"{}"); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            if self.path in ("/v1/warm", "/v1/anonymous"):
                connections.append(self.client_address)
                self.reply(200, {})
            elif self.path == "/v1/redirect":
                self.reply(302, {"error": {"code": "bad synthetic-error-secret"}},
                           location=self.redirect_url)
            elif self.path == "/v1/cancel-state":
                self.reply(200, {"ready": cancel_ready.is_set()})
            else:
                self.send_response(200)
                self.send_header("Content-Length", "65536")
                self.end_headers()
                self.wfile.write(b"{")
                self.wfile.flush()
                cancel_ready.set()
                self.close_connection = True
                self.connection.settimeout(4)
                try:
                    if self.connection.recv(1) == b"":
                        cancel_closed.set()
                    else:
                        errors.append("cancelled request sent unexpected bytes")
                except ConnectionResetError:
                    cancel_closed.set()
                except TimeoutError:
                    errors.append("cancellation left transport open")
            return
        seen.append(self.path)
        if self.path != "/v1/models":
            errors.append("model URL normalization failed")
        key = self.headers.get("Authorization")
        status = 200 if key == "Bearer synthetic-key" else 401
        if key not in ("Bearer synthetic-key", "Bearer synthetic-wrong-key"):
            errors.append("credential normalization failed")
        self.reply(status, {"data": [{"id": "test-model"}]} if status == 200 else {"error": {"code": "AuthenticationError"}})

    def do_POST(self):
        if self.path == "/v1/asr":
            seen.append(self.path)
            payload = self.rfile.read(int(self.headers["Content-Length"]))
            key = self.headers.get("Authorization")
            if key in ("Bearer synthetic-wrong-key", "Bearer synthetic-quota-key"):
                self.reply(402 if "quota" in key else 401, {"message": "synthetic-fish-key must not be displayed"})
                return
            self.check_isolation("Bearer synthetic-fish-key")
            document = BytesParser(policy=default).parsebytes(
                f"Content-Type: {self.headers['Content-Type']}\r\nMIME-Version: 1.0\r\n\r\n".encode() + payload)
            fields = {part.get_param("name", header="content-disposition"): part for part in document.iter_parts()}
            model = self.headers.get("model")
            expected = {"audio", "ignore_timestamps"}
            if model == "transcribe-1-pro":
                expected |= {"tag_audio_events", "diarize"}
            if model not in ("transcribe-1-pro", "transcribe-1") or set(fields) != expected:
                errors.append("Fish native model header / multipart fields mismatch")
            elif (fields["ignore_timestamps"].get_payload(decode=True) != b"true"
                  or fields["audio"].get_content_type() != "audio/wav"
                  or fields["audio"].get_payload(decode=True) != bytes(64)
                  or any(fields[name].get_payload(decode=True) != b"false" for name in expected - {"audio", "ignore_timestamps"})):
                errors.append("Fish native timestamps/options/audio mismatch")
            self.reply(200, {"text": " <|speaker:0|> 测试GitHub123 \n"})
            return
        if self.path in ("/v1/audio/transcriptions", "/compat/v1/audio/transcriptions"):
            seen.append(self.path)
            payload = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Authorization") == "Bearer synthetic-wrong-key":
                self.reply(401, {"error": {"code": "invalid_api_key"}})
                return
            fish = self.path.startswith("/compat/")
            expected_key = "Bearer synthetic-fish-key" if fish else "Bearer synthetic-stt-key"
            self.check_isolation(expected_key)
            document = BytesParser(policy=default).parsebytes(
                f"Content-Type: {self.headers['Content-Type']}\r\nMIME-Version: 1.0\r\n\r\n".encode() + payload)
            fields = {part.get_param("name", header="content-disposition"): part for part in document.iter_parts()}
            if set(fields) != {"model", "response_format", "file"}:
                errors.append("STT added unsupported fields or forced a recognition language")
            elif (fields["model"].get_payload(decode=True).decode() != ("fish-audio/transcribe-1" if fish else "synthetic-stt")
                  or fields["response_format"].get_payload(decode=True) != b"json"
                  or fields["file"].get_content_type() != "audio/wav"
                  or fields["file"].get_payload(decode=True) != bytes(64)):
                errors.append("STT multipart model/format/audio mismatch")
            self.reply(200, {"text": " 测试GitHub123 \n"})
            return
        if self.path == "/v1/cold-synthetic-path-secret":
            seen_http.append(self.path)
            connections.append(self.client_address)
            self.check_isolation("Bearer synthetic-metrics-key")
            if self.rfile.read(int(self.headers["Content-Length"])) != b"synthetic-request-secret":
                errors.append("timed request body changed")
            time.sleep(0.12)
            self.reply(200, {"secret": "synthetic-response-secret"}, download_delay=0.12)
            return
        seen.append(self.path)
        self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/v1/auth-format":
            self.reply(401, {"error": {"code": "AuthenticationError", "message": "The API key format is incorrect."}})
            return
        if self.path != "/v1/chat/completions" or self.headers.get("Authorization") != "Bearer synthetic-key":
            errors.append("custom completion URL/auth failed")
        self.reply(200, {})

    def check_isolation(self, expected_key):
        if self.headers.get("Authorization") != expected_key:
            errors.append("request credential crossed task boundary")
        if any(self.headers.get(name) for name in ("Cookie", "Proxy-Authorization", "x-api-key", "api-key")):
            errors.append("unexpected cookie or credential header")

    def reply(self, status, body, location=None, download_delay=0):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Set-Cookie", "synthetic-cookie=synthetic-cookie-secret; Path=/")
        if location is not None:
            self.send_header("Location", location)
        self.end_headers()
        if download_delay:
            self.wfile.write(data[:1])
            self.wfile.flush()
            time.sleep(download_delay)
            data = data[1:]
        self.wfile.write(data)
        self.wfile.flush()


with tempfile.TemporaryDirectory(prefix="aime-provider-contract-") as temp:
    executable = Path(temp) / "check"
    sources = sorted((ROOT / "Packages/AIMEVoiceKit/Sources/AIMEVoice").glob("*.swift"))
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *voice_dependency_flags(), *map(str, sources),
                    str(ROOT / "scripts/tests/VoiceProviderCheck.swift"), "-o", str(executable)], check=True, cwd=ROOT)
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server, \
            ThreadingHTTPServer(("127.0.0.1", 0), RedirectTarget) as target:
        Handler.redirect_url = f"http://127.0.0.1:{target.server_port}/synthetic-redirect-secret"
        threading.Thread(target=server.serve_forever, daemon=True).start()
        threading.Thread(target=target.serve_forever, daemon=True).start()
        try:
            result = subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}"],
                                    capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            assert "synthetic-" not in output, "synthetic secret appeared in diagnostic output"
            assert result.returncode == 0, output
            print(result.stdout, end="")
            assert cancel_closed.wait(1), "cancelled connection did not close"
        finally:
            server.shutdown()
            target.shutdown()
    assert not errors, errors
assert len(seen) == 9, seen
assert seen.count("/v1/asr") == 4, seen
assert len(connections) == 3 and len(set(connections)) == 1, "connection reuse lost across credentials/delegates"
assert not redirect_hits, "redirect target received a request"
assert seen_http.count("/v1/redirect") == 2, "redirect paths not exercised"
assert seen_http.count("/v1/cancel") == 1, "cancelled request retried"
print(f"PASS {len(seen) + len(seen_http)} loopback requests; no external account or credential accessed")
