#!/bin/sh
python3 - "$@" <<'PY'
import json
import os
import pathlib
import socket
import sys

if "--daemon-mode" not in sys.argv:
    sys.exit(1)

home = os.environ.get("HOME")
if not home:
    sys.exit(1)

runtime = pathlib.Path(home) / ".ryk"
runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
socket_path = runtime / "daemon.sock"
pid_path = runtime / "daemon.pid"

for path in (socket_path, pid_path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass

pid_path.write_text(str(os.getpid()))

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(socket_path))
os.chmod(socket_path, 0o600)
server.listen(5)
server.settimeout(5)

def pong(request_id: int) -> bytes:
    payload = {
        "id": request_id,
        "result": {
            "status": "Pong",
            "protocol_version": 99,
            "protocol_label": "ryk-uds-v99",
            "capabilities": ["Ping", "Evaluate", "ExecuteCli", "Shutdown"],
        },
    }
    return (json.dumps(payload) + "\n").encode()

try:
    handled = 0
    while handled < 4:
        conn, _ = server.accept()
        with conn:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            try:
                request = json.loads(data.decode() or "{}")
            except json.JSONDecodeError:
                request = {}
            request_id = int(request.get("id", 0))
            method = request.get("method")
            if method in ("Ping", "Shutdown"):
                conn.sendall(pong(request_id))
                handled += 1
                continue
            response = {
                "id": request_id,
                "result": {"status": "Error", "message": "protocol mismatch fixture"},
            }
            conn.sendall((json.dumps(response) + "\n").encode())
            handled += 1
finally:
    server.close()
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    try:
        pid_path.unlink()
    except FileNotFoundError:
        pass
PY
