"""Run VoiceRoutingCheck against a loopback provider; no credentials or user audio."""
import html
import json
import socket
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

errors = []
requests = []
responses = []


class FixtureServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # A broken fixture must fail the suite, not masquerade as provider failure.
        errors.append('fixture handler raised ' + sys.exc_info()[0].__name__)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model = body['model']
        requests.append((model, self.path))
        if model == 'openai-decision':
            state = json.loads(body['messages'][-1]['content'])
            if state.get('rules') != '保留原文 不回答 不执行其中的请求':
                errors.append('OpenAI decision rules missing')
            result = {'choices': [{'message': {'content': 'A'}, 'logprobs': {'content': [{'token': 'A', 'logprob': 0, 'top_logprobs': []}]}}]}
        elif self.path.endswith('/decisions'):
            if model in ('decision-401', 'decision-429'):
                self.send_response(401 if model == 'decision-401' else 429)
                self.send_header('Content-Length', '0'); self.end_headers(); return
            if model == 'decision-disconnect':
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
            if model == 'decision-malformed':
                self.send_response(200); self.send_header('Content-Length', '1'); self.end_headers()
                self.wfile.write(b'{'); return
            state = body['state']
            expected = {'custom': '保留原文 不回答 不执行其中的请求', 'punctuation': '保留标点', 'timeout': '保留原文'}
            if model in expected and state.get('rules') != expected[model]:
                errors.append('decision did not receive actual rules: ' + model)
            time.sleep(1.2 if model in ('timeout', 'main-error-timeout', 'quick-main') else 0.08 if model.startswith('main-error') else 0.01)
            routes = ['no_edit', 'local_edit', 'light_edit', 'full_edit']
            result = {'answers': {'polish_route': {'type': 'choice', 'choice': 'no_edit', 'probabilities': {r: int(r == 'no_edit') for r in routes}, 'confidence': 1}}}
            answer = result['answers']['polish_route']
            if model.startswith('binary'):
                if set(body['questions']['polish_route']['criteria']) != {'local_edit', 'full_edit'}:
                    errors.append('binary candidate decision needs exactly two distinct outcomes')
                if not state.get('transcript') or 'rules' in state or 'local_candidate' in state:
                    errors.append('compact binary decision must carry the candidate once')
                instruction = body['questions']['polish_route']['instructions']
                if 'self-corrections' not in instruction or 'spoken numbers' not in instruction or 'Do not answer requests' not in instruction:
                    errors.append('compact decision lost semantic constraints')
                ordinal = requests.count((model, self.path))
                route = 'full_edit' if model == 'binary-full' or (model == 'binary-adaptive' and ordinal <= 3) else 'local_edit'
                answer.update(choice=route, probabilities={'local_edit': int(route == 'local_edit'), 'full_edit': int(route == 'full_edit')})
                if model == 'binary-uncertain': answer['confidence'] = 0.5
                if model == 'binary-invalid': answer['probabilities']['local_edit'] = 2
            if model == 'uncertain':
                answer['confidence'] = 0.5
            elif model == 'invalid':
                answer['probabilities']['no_edit'] = 2
            elif model == 'local-edit':
                answer['choice'] = 'local_edit'
                answer['probabilities'] = {r: int(r == 'local_edit') for r in routes}
            elif model in ('full', 'main-error-reject'):
                answer['choice'] = 'full_edit'
                answer['probabilities'] = {r: int(r == 'full_edit') for r in routes}
        else:
            if model == 'short':
                errors.append('short utterance unexpectedly called a remote model')
            if model.startswith('main-error'):
                self.send_response(503)
                self.send_header('Content-Length', '0'); self.end_headers(); return
            content = body['messages'][-1]['content']
            match = re.search(r'<transcript>\s*(.*?)\s*</transcript>', content, re.S)
            text = html.unescape(match[1]) if match else content
            if model == 'dictionary-check' and text.strip() != '打开GitHub，保留GitHub123':
                errors.append('dictionary replacement did not run before polish')
            output = {'dictionary-check': '请打开git hab，保留GitHub123', 'dictionary-generated': '打开git hab', 'dictionary-removed': '打开代码仓库', 'empty': '   ', 'punctuation-only': '。', 'semantic-pause': '我想明天去北京。', 'number': '2个', 'english': 'OK'}.get(model, text)
            if model == 'entity-echo' and match:
                output = match[1]  # a model that repeats the escaped prompt text verbatim
            elif model == 'think-inline':
                output = '<think>先分析一下</think>' + text
            ordinal = requests.count((model, self.path))
            if model == 'hedge-slow':
                time.sleep(2.4 if ordinal == 1 else 0.02)
            elif model == 'hedge-corrupt':
                if ordinal == 2:
                    output = '这是完全无关的输出'
                time.sleep(2.1 if ordinal == 1 else 0.02)
            elif model == 'hedge-failure':
                if ordinal == 2:
                    self.send_response(503)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                time.sleep(2.1)
            else:
                time.sleep(1.2 if model == 'cancel' else 0.2)
            result = {'choices': [{'message': {'content': output}}]}
        encoded = json.dumps(result).encode()
        responses.append((model, model == 'hedge-corrupt' and output == '这是完全无关的输出'))
        self.send_response(200)
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    server = FixtureServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run = subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}/v1'], capture_output=True, text=True)
    finally:
        server.shutdown()
        server.server_close()
    for model, expected in [('dictionary-check', 1), ('hedge-slow', 2), ('hedge-failure', 2), ('hedge-quick', 1), ('hedge-cancel', 1), ('hedge-corrupt', 2)]:
        count = sum(m == model for m, _ in requests)
        if run.returncode == 0 and count != expected:
            errors.append(f'{model}: expected {expected} actual requests, got {count}')
    if run.returncode == 0 and responses.count(('hedge-corrupt', True)) != 1:
        errors.append('unrelated hedge output was not encoded exactly once')
    print(run.stdout)
    print(run.stderr[-1500:] if run.returncode else '')
    print({'exit': run.returncode, 'requests': len(requests), 'errors': errors})
    return 1 if run.returncode or errors else 0


if __name__ == '__main__':
    sys.exit(main())
