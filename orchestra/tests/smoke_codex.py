#!/usr/bin/env python3
"""Real Codex TUI delivery on a scratch tmux server; no credentials or model calls.

Run explicitly with an installed codex CLI: python3 orchestra/tests/smoke_codex.py.
Only the Responses endpoint is faked; Codex, tmux, and send.sh are real.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPTS = Path(__file__).resolve().parents[1] / 'skills/orchestrator/scripts'


def main():
    for binary in ('codex', 'tmux', 'git'):
        if not shutil.which(binary):
            raise SystemExit(f'{binary} is required')
    print(subprocess.check_output(['codex', '--version'], text=True).strip(), flush=True)
    with tempfile.TemporaryDirectory(prefix='orch-codex-', dir='/tmp') as tmp:
        base = Path(tmp)
        home, repo = base / 'codex-home', base / 'repo'
        home.mkdir(); repo.mkdir()
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                item = {'id': 'msg_test', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': 'ORCHESTRA_OK', 'annotations': []}]}
                events = [
                    {'type': 'response.created', 'response': {'id': 'resp_test', 'status': 'in_progress'}},
                    {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                    {'type': 'response.completed', 'response': {'id': 'resp_test', 'status': 'completed',
                     'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}},
                ]
                data = ''.join(f'event: {e["type"]}\ndata: {json.dumps(e)}\n\n' for e in events).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (home / 'config.toml').write_text(f'''model = "gpt-6-astra"
model_provider = "orchestra-test"
[model_providers.orchestra-test]
name = "Orchestra local fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
[projects."{repo}"]
trust_level = "trusted"
[tui.model_availability_nux]
gpt-6-astra = 4
''')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('CODEX_', 'ORCHESTRA_', 'ORCHESTRATOR_', 'PLAYER_', 'CLAUDE'))}
        env.pop('TMUX', None); env.pop('TMUX_PANE', None)
        env.update(CODEX_HOME=str(home), TMUX_TMPDIR=str(base))
        socket = base / f'tmux-{os.getuid()}' / 'default'

        def run(*args, check=True):
            return subprocess.run(args, env=env, cwd=repo, text=True, capture_output=True, check=check, timeout=30)

        def tm(*args, check=True):
            return run('tmux', '-S', str(socket), *args, check=check)

        def screen():
            return tm('capture-pane', '-p', '-S', '-200', '-t', '=player:', check=False).stdout

        def events():
            result = []
            for rollout in home.glob('sessions/**/*.jsonl'):
                for line in rollout.read_text().splitlines():
                    try:
                        result.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass  # a write may be in progress
            return result

        def completed():
            return sum(e.get('type') == 'event_msg' and e['payload'].get('type') == 'task_complete' for e in events())

        def wait_for(predicate, label):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(.1)
            raise AssertionError(f'Timed out: {label}\n{screen()}')

        try:
            run('git', 'init', '-q')
            socket.parent.mkdir(mode=0o700)
            command = ['env', '-u', 'TMUX', '-u', 'TMUX_PANE', 'codex', '--no-alt-screen',
                       '-C', str(repo), '-s', 'read-only', '-a', 'never', 'INITIAL_ORCHESTRA_TURN']
            tm('new-session', '-d', '-s', 'player', '-x', '160', '-y', '40', '--', shlex.join(command))
            for key, value in {'spawner': 'orchestra', 'repo': str(repo), 'session-type': 'dir', 'agent': 'codex'}.items():
                tm('set-option', '-t', '=player:', '@orchestra-' + key, value)
            wait_for(lambda: completed() == 1, 'initial turn completion')
            time.sleep(.5)  # allow the TUI to render its idle composer
            initial_requests = len(requests)  # includes CLI startup/warmup requests
            # A draft at either its end or Home must remain unsubmitted and unchanged.
            tm('send-keys', '-t', '=player:', '-l', 'USER_HALF_TYPED_DRAFT')
            wait_for(lambda: 'USER_HALF_TYPED_DRAFT' in screen(), 'draft rendered')
            for key in ('End', 'Home'):
                tm('send-keys', '-t', '=player:', key)
                time.sleep(.2)
                sent = run('bash', str(SCRIPTS / 'send.sh'), 'player', 'MUST_NOT_JOIN_DRAFT', check=False)
                assert sent.returncode == 1 and 'no text sent' in sent.stderr, sent
                time.sleep(.2)
                assert 'USER_HALF_TYPED_DRAFT' in screen(), 'draft was changed'
                assert 'MUST_NOT_JOIN_DRAFT' not in screen(), 'message entered composer'
                assert completed() == 1, 'draft was submitted'
                assert len(requests) == initial_requests, 'draft reached Responses endpoint'
            # Clear only our test-owned draft, then verify ordinary idle delivery still works.
            tm('send-keys', '-t', '=player:', 'End', 'C-u')
            wait_for(lambda: 'USER_HALF_TYPED_DRAFT' not in screen(), 'fixture draft cleared')
            time.sleep(.2)
            messages = ('IDLE_DELIVERY_ONE', 'IDLE_DELIVERY_TWO\nsecond line: "quoted" $literal',
                        'LARGE_DELIVERY\n' + 'x' * 24000 + '\nEND @missing-path')
            for index, message in enumerate(messages, 2):
                sent = run('bash', str(SCRIPTS / 'send.sh'), 'player', message)
                assert sent.stdout == 'sent to player (paste)\n', sent.stdout
                wait_for(lambda: completed() == index, f'idle delivery {index - 1}')
                expected = '[orchestrator] ' + message
                assert any(expected == part.get('text') for request in requests
                           for item in request.get('input', []) if item.get('role') == 'user'
                           for part in item.get('content', []) if isinstance(part, dict)), expected
                time.sleep(.5)
                assert completed() == index, 'message submitted more than once'
            print('PASS: drafts refused at End and Home; three idle Codex turns, multiline and 24 KiB input preserved, no manual Enter or queue', flush=True)
        finally:
            # The explicit socket is always ours, never the user server.
            tm('kill-server', check=False)
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
