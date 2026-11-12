#!/usr/bin/env python3
"""Mirror a Rex terminal block inside a plain terminal (and type into it).

Rex has no attach command, so this is a mirror rather than a second client: it
reads the block's screen as VT text and repaints it, and it forwards whatever you
type with `com.superlogical.terminal.write`. Repainting whole frames (instead of
splicing the live byte stream into the terminal) keeps the picture honest even
when the window and the block disagree about size.

Frames are driven by the block's data connection (`rex.data.terminal.v1`), not by
a timer: when output arrives the mirror repaints right away (at most once every
MIN_FRAME_GAP), and an idle block costs nothing. A slow heartbeat still repaints
a couple of times a second, in case an event was missed.

The mirror also watches the block: when the block disappears, or the program
that owned it exits (the block will close), the helper exits, which closes the
viewer float instead of leaving a frozen picture behind.

Only Python's standard library is used.
"""

import argparse
import base64
import hashlib
import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import termios
import time
import tty
import unicodedata
import urllib.parse

# Frames are painted at most this often, and at least this often when idle.
MIN_FRAME_GAP = 0.02
IDLE_REPAINT = 1.0
ALIVE_EVERY = 1.0

# A block's foreground turning into one of these means the agent is gone but the
# block's shell is still around (the block only closes when the shell exits).
SHELLS = {
    "sh",
    "bash",
    "zsh",
    "fish",
    "dash",
    "ksh",
    "mksh",
    "tcsh",
    "csh",
    "nu",
    "elvish",
    "pwsh",
    "login",
}


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


def cell_width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def crop_line(line, cols):
    """Cut a VT line at `cols` printable cells, keeping escape sequences intact.

    Without this, a block wider than the float wraps inside the terminal and
    every TUI line turns into two broken ones.
    """
    out = []
    width = 0
    i = 0
    n = len(line)
    cut = False
    while i < n:
        ch = line[i]
        if ch == "\x1b":
            j = i + 1
            if j < n and line[j] == "[":
                # CSI: parameters, then a final byte in @..~
                j += 1
                while j < n and not ("@" <= line[j] <= "~"):
                    j += 1
                j += 1
            elif j < n and line[j] in "]P_^":
                # OSC/DCS/APC/PM: ends with BEL or ST
                j += 1
                while j < n:
                    if line[j] == "\x07":
                        j += 1
                        break
                    if line[j] == "\x1b" and j + 1 < n and line[j + 1] == "\\":
                        j += 2
                        break
                    j += 1
            else:
                j += 1
            out.append(line[i:j])
            i = j
            continue
        w = cell_width(ch)
        if width + w > cols:
            cut = True
            break
        out.append(ch)
        width += w
        i += 1
    text = "".join(out)
    if cut:
        text += "\x1b[0m"
    return text


def screen(lines, rows, cols):
    """The visible screen: the last `rows` lines, each cropped to `cols` cells.

    `format` returns the screen plus scrollback; a mirror must show the screen
    only, or the top of the frame scrolls away every repaint.
    """
    body = [ln for ln in lines.split("\r\n")]
    while body and body[-1] == "":
        body.pop()
    if rows and len(body) > rows:
        body = body[-rows:]
    return [crop_line(ln, cols) for ln in body]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--block", required=True)
    ap.add_argument("--readonly", action="store_true")
    ap.add_argument("--interval", type=float, default=0.08)
    args = ap.parse_args()

    ctl = WS("/api/control", "rex.control.v1")
    ctl.send(
        1,
        json.dumps(
            {
                "type": "hello",
                "api_revision": 10,
                "client": {"kind": "cli", "name": "ask-agent.nvim", "version": "view"},
            }
        ).encode(),
    )
    while True:
        op, payload = ctl.recv()
        if op not in (1, 0):
            continue
        msg = json.loads(payload)
        if msg.get("type") == "welcome":
            break

    seq = 0

    def call(method, body):
        nonlocal seq
        seq += 1
        req_id = str(seq)
        ctl.send(1, json.dumps({"type": "request", "id": req_id, "method": method, "payload": body}).encode())
        while True:
            op, payload = ctl.recv()
            if op not in (1, 0):
                continue
            msg = json.loads(payload)
            if msg.get("type") != "response" or msg.get("id") != req_id:
                continue
            if "error" in msg:
                err = msg["error"]
                return None, f"{err.get('code', 'error')}: {err.get('message', '')}"
            return msg.get("payload"), None

    _, err = call("session.attach", {"session_id": args.session})
    if err:
        raise SystemExit("session.attach: " + err)

    block_args = {"session_id": args.session, "block_id": args.block}

    def cli_json(method):
        """`rex block call ... <method>` as JSON.

        Grid size and process state are not methods on the block socket (the
        socket exposes format/resize/process... but not `size`), while the CLI
        routes `size` to the block's layout record. Going through the CLI keeps
        the helper from hardcoding a server-internal route; it runs once a second,
        so the cost is a few milliseconds.
        """
        try:
            res = subprocess.run(
                ["rex", "block", "call", "-b", args.block, "-s", args.session, method],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, str(exc)
        if res.returncode != 0:
            return None, (res.stderr or b"").decode("utf-8", "replace").strip() or "call failed"
        try:
            return json.loads(res.stdout or b"{}"), None
        except json.JSONDecodeError:
            return None, "bad json"

    def block_size():
        payload, berr = cli_json("size")
        if berr or not payload:
            return None, berr or "no answer"
        cols = payload.get("columns")
        rows = payload.get("rows")
        if not isinstance(cols, int) or not isinstance(rows, int):
            return None, "bad size"
        return (cols, rows), None

    size, _ = block_size()
    if size:
        block_cols, block_rows = size
    else:
        # the viewer still works with a guessed grid; cropping just cannot help
        block_cols, block_rows = shutil.get_terminal_size((80, 24))

    def tty_size():
        try:
            ts = shutil.get_terminal_size((block_cols, block_rows))
            return ts.columns, ts.lines
        except OSError:
            return block_cols, block_rows

    def write(data):
        if not data:
            return
        text = data.decode("utf-8", "replace")
        _, werr = call(
            "com.superlogical.terminal.write",
            {"session_id": args.session, "block_id": args.block, "args": {"data": text}},
        )
        if werr:
            print("[ask-agent rex view] write: " + werr, file=sys.stderr, flush=True)

    # The data connection only says "there is new output": what gets painted is
    # still a whole frame, so the picture survives the float and the block
    # disagreeing about size. Without it (older server, unknown protocol) the
    # mirror falls back to polling every --interval seconds.
    live = None
    ticket, terr = call(
        "data.connect",
        {
            "session_id": args.session,
            "block_id": args.block,
            "data_ref_id": "terminal",
            "subprotocol": "rex.data.terminal.v1",
        },
    )
    if terr or not ticket:
        log("live updates off (%s); polling every %.2fs" % (terr or "no ticket", args.interval))
    else:
        try:
            live = WS("/api/data", "rex.data.terminal.v1")
            live.sock.settimeout(5)
            raw = ticket["ticket"]
            live.send(2, b"\x01" + base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
            op, hello = live.recv()  # the snapshot follows as binary frames
            live.sock.settimeout(None)
            live.buf = b""
            if not hello:
                log("live updates: empty hello")
        except (EOFError, OSError, KeyError, ValueError) as exc:
            log("live updates off (%s); polling every %.2fs" % (exc or "rejected", args.interval))
            live = None

    out = sys.stdout.buffer
    painted = None

    def paint():
        nonlocal painted, block_cols, block_rows
        payload, perr = call(
            "com.superlogical.terminal.format",
            {"session_id": args.session, "block_id": args.block, "args": {"format": "vt"}},
        )
        if perr:
            return perr
        if not payload:
            return None
        content = payload.get("content") or ""
        if content == painted:
            return None
        painted = content
        # never paint a line wider/taller than the pty: the terminal would wrap it
        cols, rows = tty_size()
        cols = min(cols, block_cols)
        rows = min(rows, block_rows)
        body = screen(content, rows, cols)
        frame = b"\x1b[H\x1b[J" + b"".join(ln.encode("utf-8", "replace") + b"\x1b[K\r\n" for ln in body)
        frame += b"\x1b[?25h"
        out.write(frame)
        out.flush()
        return None

    def gone():
        """Why the viewer should close, or None. Keeps a dead block from hanging."""
        nonlocal initial_fg
        payload, perr = cli_json("process")
        if perr:
            return "the block is gone"
        payload = payload or {}
        last_exit = payload.get("last_exit")
        if last_exit:
            code = last_exit.get("exit_code")
            return "the program in the block exited (exit %s)" % code
        fg = payload.get("foreground") or {}
        name = (fg.get("name") or "").lstrip("-")
        if initial_fg is None:
            initial_fg = name
        elif initial_fg not in SHELLS and name in SHELLS:
            # The agent exited but the block's shell survived: the mirror would
            # sit there showing a prompt nobody asked for. This is exactly what
            # `Ctrl-C` in the viewer does, so close the viewer with it.
            return "the agent exited — the block is back to a shell"
        payload, perr = cli_json("size")
        if perr:
            return "the block is gone"
        return None

    paint()

    initial_fg = None  # foreground command when the viewer opened

    stdin = sys.stdin.fileno()
    interactive = not args.readonly and os.isatty(stdin)
    if interactive:
        saved = termios.tcgetattr(stdin)
        tty.setraw(stdin)

    def farewell(reason):
        out.write(("\r\n\x1b[0m[ask-agent] %s — closing the viewer\r\n" % reason).encode())
        out.flush()

    dirty = True  # the first frame
    painted_at = 0.0
    next_alive = time.monotonic() + ALIVE_EVERY
    try:
        while True:
            now = time.monotonic()
            # Wake up for whichever comes first: a due paint, the health check,
            # or the fallback poll.
            wake = min(
                next_alive,
                painted_at + (args.interval if live is None else IDLE_REPAINT),
            )
            if dirty:
                wake = min(wake, painted_at + MIN_FRAME_GAP)
            fds = [stdin] + ([live.sock] if live else [])
            if live and len(live.buf) >= 2:
                wake = now  # a frame is already buffered
            timeout = max(0.0, wake - now)
            ready, _, _ = select.select(fds, [], [], timeout)
            if stdin in ready:
                chunk = os.read(stdin, 4096)
                if not chunk:
                    break
                if interactive:
                    write(chunk)
                    dirty = True  # show the echo without waiting for rex to answer
            if live and live.sock in ready:
                try:
                    op, _payload = live.recv()
                except (EOFError, OSError) as exc:
                    log("live updates lost (%s); polling every %.2fs" % (exc or "closed", args.interval))
                    live = None
                else:
                    if op == 0x8:  # close
                        live = None
                    elif op in (0x0, 0x1, 0x2):
                        dirty = True
            now = time.monotonic()
            if not dirty and now >= painted_at + (args.interval if live is None else IDLE_REPAINT):
                dirty = True
            if dirty and now - painted_at >= MIN_FRAME_GAP:
                err = paint()
                painted_at = time.monotonic()
                dirty = False
                if err:
                    farewell("the block is gone")
                    break
            if time.monotonic() >= next_alive:
                reason = gone()
                if reason:
                    farewell(reason)
                    break
                fresh, _ = block_size()
                if fresh:
                    block_cols, block_rows = fresh
                next_alive = time.monotonic() + ALIVE_EVERY
    finally:
        if interactive:
            termios.tcsetattr(stdin, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt, EOFError):
        pass
    except SystemExit as e:
        if e.code not in (0, None):
            print("[ask-agent rex view] " + str(e), file=sys.stderr, flush=True)
            sys.exit(1)
