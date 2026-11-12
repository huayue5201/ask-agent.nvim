#!/usr/bin/env python3
"""Show a Rex terminal block inside a plain terminal.

Rex has no "attach" for an existing block, so this is a viewer, not a second
client: it paints the block's current screen with `rex capture --format=vt`,
then follows the block's data stream (rex.data.terminal.v1) and writes the live
bytes to stdout. Input is never forwarded — type in Rex itself.

The data stream starts with Ghostty's binary snapshot; we skip it by walking the
snapshot's record framing (magic + tag/len/crc records) up to FINISH, then pass
every following byte through. Skipping the snapshot keeps this helper free of a
full terminal-state decoder, at the cost of a few milliseconds of output
between the capture and the data connection.

Only Python's standard library is used.
"""

import argparse
import base64
import hashlib
import json
import os
import select
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

MAGIC = b"GHOSTSNP"
FINISH_TAG = 6


def log(msg):
    print("[ask-agent rex view] " + msg, file=sys.stderr, flush=True)


def rex_server():
    """unix socket path from REX_SERVER, else `rex server status --json`."""
    env = os.environ.get("REX_SERVER", "")
    if env.startswith("unix://"):
        return urllib.parse.unquote(env[len("unix://") :])
    out = subprocess.run(
        ["rex", "server", "status", "--json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=5,
    )
    data = json.loads(out.stdout or b"{}")
    endpoint = data.get("endpoint", "")
    if endpoint.startswith("unix://"):
        return urllib.parse.unquote(endpoint[len("unix://") :])
    raise SystemExit("cannot find the Rex server socket")


class WS:
    """Minimal RFC 6455 client over a stream socket (no extensions)."""

    def __init__(self, path, subprotocol):
        self.buf = b""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(rex_server())
        self.sock.settimeout(None)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: localhost\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Protocol: {subprotocol}\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SystemExit("websocket handshake closed")
            buf += chunk
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        lines = head.decode(errors="replace").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise SystemExit("websocket handshake failed: " + lines[0])
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        if headers.get("sec-websocket-accept") != expected:
            raise SystemExit("websocket handshake: bad accept key")

    def _recv(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(max(4096, n - len(self.buf)))
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv(self):
        """-> (opcode, payload); answers pings itself."""
        while True:
            b1, b2 = self._recv(2)
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv(8))[0]
            mask = self._recv(4) if masked else None
            payload = self._recv(n) if n else b""
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:  # ping
                self.send(0xA, payload)
                continue
            if opcode == 0xA:  # pong
                continue
            return opcode, payload


class SnapshotSkipper:
    """Incremental: drop the Ghostty snapshot prefix, pass everything after it."""

    def __init__(self):
        self.buf = b""
        self.envelope = False
        self.done = False

    def feed(self, data):
        if self.done:
            return data
        self.buf += data
        while not self.done:
            if not self.envelope:
                if len(self.buf) < 10:
                    break
                if self.buf[:8] != MAGIC:
                    log("stream does not start with a Ghostty snapshot — passing through")
                    self.done = True
                    break
                self.buf = self.buf[10:]
                self.envelope = True
                continue
            if len(self.buf) < 10:
                break
            tag, length, _crc = struct.unpack("<HII", self.buf[:10])
            if tag == FINISH_TAG:
                self.buf = self.buf[10:]
                self.done = True
                break
            if len(self.buf) < 10 + length:
                break
            self.buf = self.buf[10 + length :]
        if self.done:
            out, self.buf = self.buf, b""
            return out
        return b""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--block", required=True)
    ap.add_argument("--capture", default="1")
    args = ap.parse_args()

    if args.capture == "1":
        try:
            cap = subprocess.run(
                ["rex", "capture", "-s", args.session, "-b", args.block, "--format=vt"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            if cap.returncode == 0 and cap.stdout:
                sys.stdout.buffer.write(cap.stdout)
                sys.stdout.buffer.flush()
        except Exception as e:  # a failed capture still leaves the live stream
            log(f"capture failed: {e}")

    ctl = WS("/api/control", "rex.control.v1")
    rev = 10
    ctl.send(
        1,
        json.dumps(
            {
                "type": "hello",
                "api_revision": rev,
                "client": {"kind": "cli", "name": "ask-agent.nvim", "version": "view"},
            }
        ).encode(),
    )
    while True:
        op, payload = ctl.recv()
        if op not in (1, 0):  # text, or a continuation of a fragmented text message
            continue
        msg = json.loads(payload)
        if msg.get("type") == "welcome":
            rev = msg.get("api_revision", rev)
            break

    queue = []

    def call(method, body):
        req_id = str(len(queue) + 1) + "-" + str(int(time.time() * 1000))
        ctl.send(1, json.dumps({"type": "request", "id": req_id, "method": method, "payload": body}).encode())
        queue.append(req_id)
        while True:
            op, payload = ctl.recv()
            if op not in (1, 0):
                continue
            msg = json.loads(payload)
            if msg.get("type") != "response" or msg.get("id") != req_id:
                continue
            queue.remove(req_id)
            if "error" in msg:
                err = msg["error"]
                return None, f"{err.get('code', 'error')}: {err.get('message', '')}"
            return msg.get("payload"), None

    _, err = call("session.attach", {"session_id": args.session})
    if err:
        raise SystemExit("session.attach: " + err)
    ticket, err = call(
        "data.connect",
        {
            "session_id": args.session,
            "block_id": args.block,
            "data_ref_id": "terminal",
            "subprotocol": "rex.data.terminal.v1",
        },
    )
    if err:
        raise SystemExit("data.connect: " + err)

    data = WS("/api/data", "rex.data.terminal.v1")
    data.send(2, b"\x01" + base64.urlsafe_b64decode(ticket["ticket"] + "=" * (-len(ticket["ticket"]) % 4)))

    op, hello = data.recv()
    if not hello or hello[0] != 0x81:
        raise SystemExit("data connection rejected: " + (hello[1:].decode(errors="replace") or "unknown reason"))

    skip = SnapshotSkipper()
    out = sys.stdout.buffer
    while True:
        # The control connection must stay healthy (pings, events) for as long
        # as the data stream lives, so both sockets are serviced here.
        if len(data.buf) < 2:
            ready, _, _ = select.select([data.sock, ctl.sock], [], [], 1.0)
            if ctl.sock in ready:
                try:
                    ctl.recv()
                except (OSError, EOFError):
                    pass
            if data.sock not in ready:
                continue
        op, payload = data.recv()
        if op == 0x8:  # close
            break
        if op not in (0x0, 0x2):  # binary, or a continuation of a fragmented message
            continue
        live = skip.feed(payload)
        if os.environ.get("REXVIEW_DEBUG"):
            log(f"frame op={op} len={len(payload)} live={len(live)}")
        if live:
            out.write(live)
            out.flush()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    except EOFError:
        pass
    except SystemExit as e:
        if e.code not in (0, None):
            log(str(e))
            sys.exit(1)
