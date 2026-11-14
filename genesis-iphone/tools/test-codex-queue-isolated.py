#!/usr/bin/env python3
"""Exercise the installed CLI queue with disposable state and a loopback-only model.

Creates synthetic sessions only. Never reads production Codex state or credentials,
never starts/restarts the managed daemon, and never contacts a real model provider.
"""
import base64
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time


class WebSocket:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(12)
        self.sock.connect(str(path))
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                           "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                           f"Sec-WebSocket-Key: {key}\r\n\r\n").encode())
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            header += self.sock.recv(1)
            assert len(header) < 16384
        assert b"101 Switching Protocols" in header
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert expected in header
        self.next_id = 1
        self.events = []

    def send(self, obj, opcode=1):
        data = json.dumps(obj).encode() if opcode == 1 else obj
        mask = os.urandom(4)
        prefix = bytes([0x80 | opcode])
        if len(data) < 126:
            prefix += bytes([0x80 | len(data)])
        elif len(data) <= 65535:
            prefix += bytes([0x80 | 126]) + struct.pack("!H", len(data))
        else:
            prefix += bytes([0x80 | 127]) + struct.pack("!Q", len(data))
        self.sock.sendall(prefix + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(data)))

    def exact(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise EOFError("fixture socket closed")
            data += chunk
        return data

    def receive(self):
        while True:
            first, second = self.exact(2)
            assert first & 0x80, "fixture expects unfragmented messages"
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", self.exact(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.exact(8))[0]
            assert size <= 4 * 1024 * 1024
            mask = self.exact(4) if second & 0x80 else None
            data = self.exact(size)
            if mask:
                data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
            if first & 15 == 9:
                self.send(data, 10)
            elif first & 15 == 1:
                return json.loads(data)
            elif first & 15 == 8:
                raise EOFError("fixture WebSocket closed")

    def rpc(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.send({"id": request_id, "method": method, "params": params})
        while True:
            response = self.receive()
            if response.get("id") == request_id:
                if "error" in response:
                    raise RuntimeError(response["error"])
                return response["result"]
            self.events.append(response)


class FixtureProvider(http.server.BaseHTTPRequestHandler):
    requests = []
    hold_next = False
    held = threading.Event()
    release = threading.Event()
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        assert 0 <= length <= 4 * 1024 * 1024
        body = self.rfile.read(length)
        self.requests.append(body)
        if FixtureProvider.hold_next:
            FixtureProvider.hold_next = False
            FixtureProvider.held.set()
            assert FixtureProvider.release.wait(15), "fixture release deadline"
        item = {"id": "msg_genesis_fixture", "type": "message", "status": "completed",
                "role": "assistant", "content": [{"type": "output_text", "text": "Fixture complete."}]}
        events = [
            {"type": "response.created", "response": {"id": "resp_genesis_fixture", "status": "in_progress"}},
            {"type": "response.output_item.added", "output_index": 0, "item": item},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {"id": "resp_genesis_fixture", "status": "completed", "output": [item],
                "usage": {"input_tokens": 5, "output_tokens": 3, "total_tokens": 8}}},
        ]
        payload = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"), help="CLI binary to exercise")
    codex = parser.parse_args().codex
    assert codex
    version = subprocess.check_output([codex, "--version"], text=True).strip()
    report = {"cli": version, "productionStateTouched": False, "modelNetwork": "loopback mock only", "checks": []}
    with tempfile.TemporaryDirectory(prefix="genesis-queue-", dir="/tmp") as temp:
        root = Path(temp)
        home = root / "codex"
        home.mkdir(mode=0o700)
        work = root / "workspace"
        work.mkdir()
        provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureProvider)
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        (home / "config.toml").write_text(f'''model = "gpt-5.4"
model_provider = "genesis_fixture"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "file"
[features]
plugins = false
daemon_auto_start = false
[analytics]
enabled = false
[model_providers.genesis_fixture]
name = "Genesis isolated test"
base_url = "http://127.0.0.1:{provider.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
''')
        env = {k: v for k, v in os.environ.items() if not any(x in k for x in ("TOKEN", "API_KEY", "SECRET", "PASSWORD", "OPENAI_", "CODEX_"))}
        env["CODEX_HOME"] = str(home)
        endpoint_path = root / "fixture.sock"
        endpoint = "unix://" + str(endpoint_path)
        log = open(root / "server.log", "w+")
        server = subprocess.Popen([codex, "app-server", "--listen", endpoint], env=env, cwd=work,
                                  stdout=log, stderr=log)
        other_server = None
        other_client = None
        client = None
        try:
            deadline = time.monotonic() + 15
            while not endpoint_path.exists():
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError("Isolated fixture failed to start: " + log.read()[-1600:])
                assert time.monotonic() < deadline, "fixture startup deadline"
                time.sleep(0.05)
            client = WebSocket(endpoint_path)
            client.rpc("initialize", {"clientInfo": {"name": "genesis-queue-fixture", "version": "0.1"},
                                       "capabilities": {"experimentalApi": True}})
            client.send({"method": "initialized", "params": {}})
            thread = client.rpc("thread/start", {"cwd": str(work), "model": "gpt-5.4", "modelProvider": "genesis_fixture",
                                                   "approvalPolicy": "never", "sandbox": "read-only"})["thread"]
            thread_id = thread["id"]
            assert re.fullmatch(r"[0-9a-f-]{36}", thread_id)
            report["checks"].append("new synthetic thread generated by public app-server")
            fixture_text = "Genesis isolated queue fixture. Return the fixed mock response; no tools."
            command = subprocess.run([codex, "queue", "--remote", endpoint, "--thread", thread_id, "--message", fixture_text],
                                     env=env, cwd=work, text=True, capture_output=True, timeout=20)
            assert command.returncode == 0, command.stderr[-1000:]
            match = re.fullmatch(r"Queued message ([0-9a-f-]{36}) for thread ([0-9a-f-]{36})\.\n?", command.stdout)
            assert match and match[2] == thread_id, "unexpected acknowledgement"
            report["checks"].append("actual CLI returns exact queue UUID and requested thread UUID")
            report["stdoutGrammar"] = "Queued message <UUID> for thread <UUID>."
            deadline = time.monotonic() + 20
            completed = None
            while time.monotonic() < deadline:
                messages = client.events
                client.events = []
                for event in messages:
                    if event.get("method") == "turn/completed":
                        completed = event["params"]["turn"]
                if completed:
                    break
                client.rpc("thread/read", {"threadId": thread_id, "includeTurns": False})
                time.sleep(0.1)
            assert completed and completed["status"] == "completed", "queued fixture did not complete"
            queue = client.rpc("thread/queue/list", {"threadId": thread_id})
            assert queue["data"] == []
            assert len(FixtureProvider.requests) == 1, "queue ran more than once"
            assert fixture_text.encode() in FixtureProvider.requests[0]
            report["checks"].append("loaded idle thread consumes once through loopback provider without --resume")
            report["checks"].append("completed turn observed and queue emptied")

            # A separate server shares only disposable persisted state. It never
            # resumes/starts our fixture thread, mirroring separate desktop ownership.
            other_path = home / "app-server-control" / "app-server-control.sock"
            other_path.parent.mkdir(mode=0o700, exist_ok=True)
            other_endpoint = "unix://" + str(other_path)
            other_server = subprocess.Popen([codex, "app-server", "--listen", "unix://"],
                                            env=env, cwd=work, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while not other_path.exists():
                assert other_server.poll() is None and time.monotonic() < deadline
                time.sleep(0.05)
            other_client = WebSocket(other_path)
            other_client.rpc("initialize", {"clientInfo": {"name": "genesis-queue-producer-fixture", "version": "0.1"},
                                             "capabilities": {"experimentalApi": True}})
            other_client.send({"method": "initialized", "params": {}})
            assert other_client.rpc("thread/loaded/list", {})["data"] == []
            cross_text = "Genesis cross-process durable queue fixture. No tools."
            started_at = time.monotonic()
            command = subprocess.run([codex, "queue", "--thread", thread_id, "--message=" + cross_text],
                                     env=env, cwd=work, text=True, capture_output=True, timeout=20)
            assert command.returncode == 0, command.stderr[-1000:]
            match = re.fullmatch(r"Queued message ([0-9a-f-]{36}) for thread ([0-9a-f-]{36})\.\n?", command.stdout)
            assert match and match[2] == thread_id
            queued_id = match[1]
            queue = other_client.rpc("thread/queue/list", {"threadId": thread_id})
            assert any(item["id"] == queued_id for item in queue["data"]), "cross-process message was not persisted"
            report["checks"].append("other non-owning server persists queue item without loading thread")
            report["checks"].append("production invocation discovers default Unix socket without --remote; --message= accepted")
            deadline = time.monotonic() + 20
            while len(FixtureProvider.requests) < 2:
                assert time.monotonic() < deadline, "owning process did not consume external queue"
                time.sleep(0.1)
            report["crossProcessPickupSeconds"] = round(time.monotonic() - started_at, 3)
            assert cross_text.encode() in FixtureProvider.requests[1]
            deadline = time.monotonic() + 5
            while other_client.rpc("thread/queue/list", {"threadId": thread_id})["data"]:
                assert time.monotonic() < deadline
                time.sleep(0.1)
            assert other_client.rpc("thread/loaded/list", {})["data"] == []
            report["checks"].append("existing owner consumes external queue exactly once; producer remains unloaded")

            # Hold a synthetic model response and queue one more message while busy.
            FixtureProvider.hold_next = True
            client.rpc("turn/start", {"threadId": thread_id, "input": [{"type": "text", "text": "Genesis busy-turn fixture. No tools."}]})
            assert FixtureProvider.held.wait(5)
            busy_text = "Genesis queued-follow-up after busy fixture. No tools."
            command = subprocess.run([codex, "queue", "--thread", thread_id, "--message=" + busy_text],
                                     env=env, cwd=work, text=True, capture_output=True, timeout=20)
            assert command.returncode == 0
            assert len(FixtureProvider.requests) == 3, "queued follow-up interrupted active fixture"
            queue = other_client.rpc("thread/queue/list", {"threadId": thread_id})
            assert len(queue["data"]) == 1
            FixtureProvider.release.set()
            deadline = time.monotonic() + 10
            while len(FixtureProvider.requests) < 4:
                assert time.monotonic() < deadline, "follow-up did not run after active turn"
                time.sleep(0.1)
            assert busy_text.encode() in FixtureProvider.requests[3]
            deadline = time.monotonic() + 5
            while other_client.rpc("thread/queue/list", {"threadId": thread_id})["data"]:
                assert time.monotonic() < deadline
                time.sleep(0.1)
            assert len(FixtureProvider.requests) == 4
            report["checks"].append("busy owner retains external message and consumes once after current turn completes")
            report["passed"] = True
        finally:
            FixtureProvider.release.set()
            if other_client:
                other_client.sock.close()
            if other_server:
                other_server.terminate()
                try:
                    other_server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    other_server.kill()
                    other_server.wait(timeout=5)
            if client:
                client.sock.close()
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            provider.shutdown()
            log.close()
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
