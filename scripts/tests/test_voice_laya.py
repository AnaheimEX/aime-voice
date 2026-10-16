#!/usr/bin/env python3
"""Loopback-only Laya contract checks, no user credentials or app build.

python3 scripts/tests/test_voice_laya.py             # compile Swift + run all
python3 scripts/tests/test_voice_laya.py /path/check # reuse a compiled check
python3 scripts/tests/test_voice_laya.py --python-only # evaluator/mock checks

Compilation prepares SwiftPM dependencies like the routing CI entrypoint,
then compiles AIMEVoice/*.swift with Swift 6 and -parse-as-library. Missing Laya core APIs cause
a visible compilation failure, never a skipped or falsely passing Swift suite.
"""

import argparse
from test_voice_lifecycle import voice_dependency_flags
from collections import Counter
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("evaluate_laya", ROOT / "scripts/evaluate-laya.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)
TEXT = "请保留专名GitHub和数字123。"
POLISH_CASES = {"light", "heavy", "boundary", "custom-accept", "off", "shadow", "shadow-error"}
ABSTAIN_CASES = {"custom-action", "custom-safe", "low-need-action", "low-safe-action", "unsafe", "high-none", "low-light", "low-none-action"}
UNAVAILABLE_CASES = {"unauthorized", "rate-limit", "server-error", "disconnect", "malformed-json", "missing-question", "missing-confidence", "invalid-confidence", "missing-action", "wrong-noul-type", "out-of-range", "unknown-strategy", "null-answer", "timeout"}
SWIFT_CASES = POLISH_CASES | ABSTAIN_CASES | UNAVAILABLE_CASES | {"none", "custom-none", "keepalive", "probe-light", "probe-heavy", "cancel-probe", "cancel-process", "probe-timeout"}


def answer(need=0.8, strategy="light", safe=0.9, need_action=0.9, safe_action=0.9):
    return {"answers": {
        "need_polish": {"noul": need, "confidence": 0.93, "action": {"act_probability": need_action}},
        "strategy": {"choice": strategy,
                     "probabilities": {key: 0.9 if key == strategy else 0.05 for key in evaluation.STRATEGIES}},
        "safe_to_edit": {"noul": safe, "confidence": 0.92, "action": {"act_probability": safe_action}},
    }}


def response_for(name):
    if name in {"none", "keepalive", "shadow"}:
        return answer(need=0.1, strategy="none")
    if name in {"heavy", "probe-heavy"}:
        return answer(strategy="heavy")
    if name == "boundary":
        return answer(need=0.5, safe=0.5, need_action=0.5, safe_action=0.5)
    if name == "custom-none":
        return answer(need=0.8, strategy="none", safe=0.95)
    if name == "custom-safe":
        return answer(need=0.9, safe=0.8)
    if name == "low-need-action":
        return answer(need_action=0.49)
    if name == "low-safe-action":
        return answer(safe_action=0.49)
    if name == "low-none-action":
        return answer(need=0.1, strategy="none", need_action=0.49)
    if name == "unsafe":
        return answer(safe=0.49)
    if name == "high-none":
        return answer(strategy="none")
    if name == "low-light":
        return answer(need=0.1)
    result = answer()
    if name == "missing-question":
        del result["answers"]["safe_to_edit"]
    elif name == "missing-confidence":
        del result["answers"]["safe_to_edit"]["confidence"]
    elif name == "invalid-confidence":
        result["answers"]["safe_to_edit"]["confidence"] = -0.1
    elif name == "missing-action":
        del result["answers"]["safe_to_edit"]["action"]
    elif name == "wrong-noul-type":
        result["answers"]["need_polish"]["noul"] = "0.8"
    elif name == "out-of-range":
        result["answers"]["need_polish"]["noul"] = 1.01
    elif name == "unknown-strategy":
        result["answers"]["strategy"]["choice"] = "rewrite"
    elif name == "null-answer":
        result["answers"]["safe_to_edit"] = None
    return result


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.events, self.errors, self.lock = [], [], threading.Lock()

    def event(self, name, kind, peer):
        with self.lock:
            self.events.append((name, kind, peer, time.monotonic()))

    def check(self, condition, message):
        if not condition:
            with self.lock:
                self.errors.append(message)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, payload, status=200):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # Expected when deadline/cancellation closes the request.

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, TypeError):
            self.server.check(False, "invalid request JSON")
            self.send(b"{}", 400)
            return
        if self.path == "/v1/chat/completions":
            name = body.get("model", "unknown")
            self.server.event(name, "polish", self.client_address)
            self.server.check(name in POLISH_CASES, f"unexpected polish: {name}")
            self.server.check(self.headers.get("Authorization") == "Bearer synthetic-polish", "polish authentication")
            self.server.check(TEXT in json.dumps(body, ensure_ascii=False), "polish must receive original transcript")
            self.send({"choices": [{"message": {"content": TEXT}}]})
            return
        key = self.headers.get("X-API-Key", "")
        name = key.removeprefix("synthetic-laya:")
        self.server.event(name, "predict", self.client_address)
        self.server.check(self.path == "/predict", "Laya endpoint must be /predict")
        self.server.check(key.startswith("synthetic-laya:") and name in SWIFT_CASES | {"python", "python-timeout", "python-trickle"}, "X-API-Key authentication")
        self.server.check(self.headers.get("Authorization") is None, "Laya must not send Bearer authentication")
        self.server.check(self.headers.get("Content-Type", "").split(";")[0] == "application/json", "JSON content type")
        self.server.check(set(body) == {"state", "questions"}, "exact body keys must be state/questions, no model")
        state = body.get("state")
        self.server.check(isinstance(state, str) and TEXT in state, "state must be a String containing transcript")
        questions = body.get("questions", {})
        self.server.check(isinstance(questions, dict) and set(questions) == {"need_polish", "strategy", "safe_to_edit"}, "exact three questions")
        if isinstance(questions, dict):
            for question in ("need_polish", "safe_to_edit"):
                self.server.check(isinstance(questions.get(question), dict) and questions[question].get("type") == "noul", f"{question} must be noul")
            strategy = questions.get("strategy", {})
            self.server.check(isinstance(strategy, dict) and strategy.get("type") == "choice", "strategy must be choice")
            criteria = strategy.get("criteria", {}) if isinstance(strategy, dict) else {}
            self.server.check(criteria == ["none", "light", "heavy"], "exact strategy criteria")
        if name == "disconnect":
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if name in {"timeout", "probe-timeout", "cancel-probe", "cancel-process", "python-timeout"}:
            time.sleep(1.2)
        if name in {"unauthorized", "rate-limit", "server-error", "shadow-error"}:
            self.send({"error": "synthetic failure"}, {"unauthorized": 401, "rate-limit": 429}.get(name, 503))
        elif name == "malformed-json":
            self.send(b"{")
        elif name == "python-trickle":
            payload = json.dumps(answer()).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                for byte in payload:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.05)
            except OSError:
                pass
        else:
            self.send(response_for(name))


def evaluator_checks(base_url, server):
    samples = evaluation.load_samples(evaluation.DEFAULT_DATA)
    required_tags = {"否定", "强调", "专名", "改口", "数字", "重复", "口癖", "混输"}
    assert required_tags <= {tag for sample in samples for tag in sample["tags"]}
    assert {sample["strategy"] for sample in samples} == set(evaluation.STRATEGIES)
    for name in ABSTAIN_CASES:
        threshold = 0.85 if name == "custom-safe" else 0.5
        action_threshold = 0.95 if name == "custom-action" else 0.5
        assert evaluation.classify(response_for(name), threshold, action_threshold)["status"] == "abstain", name
    assert evaluation.classify(response_for("boundary"))["route"] == "light_edit"
    assert evaluation.classify(response_for("none"))["probability"] == 0.1
    assert evaluation.classify(response_for("custom-none"), 0.9)["route"] == "no_edit"
    assert evaluation.classify(response_for("heavy"))["route"] == "full_edit"
    invalid = [response_for(name) for name in ("missing-question", "missing-confidence", "invalid-confidence", "missing-action", "wrong-noul-type", "out-of-range", "unknown-strategy", "null-answer")]
    for value in (True, -0.01, float("nan"), float("inf")):
        item = answer()
        item["answers"]["safe_to_edit"]["action"]["act_probability"] = value
        invalid.append(item)
    for item in invalid:
        try:
            evaluation.classify(item)
        except (ValueError, KeyError, TypeError):
            pass
        else:
            raise AssertionError("malformed answer accepted")
    # Every matrix cell and fail-open bucket is exercised with hand-computed counts.
    expected = [{"need_polish": label, "strategy": "light" if label else "none"} for label in (True, False, False, True, True, False)]
    predictions = [evaluation.classify(answer()), evaluation.classify(answer(need=0.1, strategy="none")),
                   evaluation.classify(answer()), evaluation.classify(answer(need=0.1, strategy="none")),
                   {"status": "abstain"}, {"status": "unavailable", "reason": "timeout"}]
    for index, prediction in enumerate(predictions, 1):
        prediction["elapsed_ms"] = index * 10
    report = evaluation.summarize(expected, predictions)
    assert report["confusion_matrix"] == {"TP": 1, "TN": 1, "FP": 1, "FN": 1}
    assert report["covered"] == 4 and report["coverage"] == 4 / 6
    assert report["fail_open"] == {"abstain": {"count": 1, "label_need_polish": 1}, "unavailable": {"count": 1, "label_need_polish": 0}}
    assert report["latency_ms"]["p50"] == 35 and report["latency_ms"]["p95"] == 57.5
    # Synthetic test results are deliberately not printed as a real service matrix.
    for name in ("python", "python-timeout", "python-trickle", "unauthorized", "malformed-json"):
        client = evaluation.PredictClient(base_url, f"synthetic-laya:{name}", 500)
        try:
            result = client.predict(TEXT, 0.5, 0.5)
            if name == "python":
                assert result["status"] == "covered"
                assert client.predict(TEXT, 0.5, 0.5)["status"] == "covered"
            else:
                assert result["status"] == "unavailable", name
                if name.startswith("python-"):
                    assert result["reason"] == "timeout" and 400 <= result["elapsed_ms"] < 900, name
        finally:
            client.close()
    connections = [event[2] for event in server.events if event[0] == "python"]
    assert len(connections) == 2 and connections[0] == connections[1], "evaluator HTTP keepalive"
    # CLI reads only the two explicit environment values; captures output to check
    # synthetic key redaction and avoids shell interpolation of credentials.
    with tempfile.TemporaryDirectory(prefix="aime-laya-data-") as temporary:
        data = Path(temporary) / "samples.jsonl"
        data.write_text(json.dumps({"id": "synthetic", "text": TEXT, "need_polish": True, "strategy": "light", "tags": ["模拟"]}, ensure_ascii=False) + "\n", encoding="utf-8")
        key = "synthetic-laya:python"
        run = subprocess.run([sys.executable, str(ROOT / "scripts/evaluate-laya.py"), "--http-contract-only", "--data", str(data)],
                             env={"LAYA_BASE_URL": base_url, "LAYA_API_KEY": key, "PYTHONDONTWRITEBYTECODE": "1"},
                             text=True, capture_output=True, timeout=5)
        assert run.returncode == 0 and key not in run.stdout + run.stderr, "evaluator CLI / credential redaction"
        assert json.loads(run.stdout)["covered"] == 1
    print(f"PASS Python evaluator: {len(samples)} labels, gates, malformed answers, matrix arithmetic, percentiles, keepalive, timeout, CLI")


def swift_checks(executable, base_url, server):
    with server.lock:
        offset = len(server.events)
    run = subprocess.run([str(executable), base_url], text=True, capture_output=True, timeout=45, cwd=ROOT)
    print(run.stdout, end="")
    if run.returncode:
        # Only synthetic loopback settings exist in the executable.
        print(run.stderr[-4000:], file=sys.stderr)
        raise AssertionError(f"Swift Laya checks failed ({run.returncode})")
    events = server.events[offset:]
    predictions = Counter(name for name, kind, _, _ in events if kind == "predict")
    polish = Counter(name for name, kind, _, _ in events if kind == "polish")
    expected = {name: (2 if name == "keepalive" else 1) for name in SWIFT_CASES - {"off"}}
    assert predictions == expected, f"predict request counts: {predictions}"
    assert polish == Counter({name: 1 for name in POLISH_CASES}), f"polish request counts: {polish}"
    keepalive = [peer for name, kind, peer, _ in events if name == "keepalive" and kind == "predict"]
    assert len(keepalive) == 2 and keepalive[0] == keepalive[1], "Swift /predict connection reuse"
    for name in POLISH_CASES - {"off", "shadow", "shadow-error"}:
        kinds = [kind for event_name, kind, _, _ in events if event_name == name]
        assert kinds == ["predict", "polish"], f"accelerate must classify before polish: {name}"
    print(f"PASS HTTP assertions: {sum(predictions.values())} predictions, {sum(polish.values())} polish requests; no fallback polish after abstention/failure/cancel")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("executable", nargs="?", type=Path)
    parser.add_argument("--python-only", action="store_true")
    args = parser.parse_args()
    if args.python_only and args.executable:
        parser.error("--python-only cannot be combined with an executable")
    with tempfile.TemporaryDirectory(prefix="aime-laya-contract-") as temporary:
        executable = args.executable.resolve() if args.executable else Path(temporary) / "VoiceLayaCheck"
        if not args.python_only and args.executable is None:
            sources = sorted((ROOT / "Packages/AIMEKit/Sources/AIMEVoice").glob("*.swift"))
            compilation = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *voice_dependency_flags(), *map(str, sources),
                                          str(ROOT / "scripts/tests/VoiceLayaCheck.swift"), "-o", str(executable)],
                                         cwd=ROOT, capture_output=True, text=True)
            if compilation.returncode:
                print(compilation.stderr, file=sys.stderr)
                raise AssertionError("Swift Laya compilation failed")
            print("PASS Swift Laya compilation")
        with Server() as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base_url = f"http://127.0.0.1:{server.server_port}"
                evaluator_checks(base_url, server)
                if not args.python_only:
                    swift_checks(executable, base_url, server)
                assert not server.errors, "HTTP contract failures: " + "; ".join(server.errors)
            finally:
                server.shutdown()
                thread.join(timeout=2)
    print("PASS Python-only loopback checks (Swift not run)" if args.python_only else "PASS Laya loopback contract suite")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.SubprocessError, OSError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
