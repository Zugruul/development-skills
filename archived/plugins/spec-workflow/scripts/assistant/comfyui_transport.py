"""Owned POSIX OpenSSH tunnel and bounded native ComfyUI HTTP/WebSocket IO."""
import base64
import hashlib
import http.client
import json
import os
import select
import socket
import struct
import subprocess
import threading
import time

from assistant import remote_control


class TransportError(Exception):
    def __init__(self):
        super().__init__("ComfyUI tunnel or bounded API transport unavailable")


def ssh_argv(entry, port):
    # Reuse the control client's audited isolation options, replacing only its
    # class-specific key and no-forwarding posture. No control grant is changed.
    adapted = {key: entry[key] for key in ("host", "port", "user", "knownHosts")}
    adapted["keys"] = {"inspect": entry["keys"]["tunnel"], "cancel": entry["keys"]["tunnel"]}
    # Validation is performed by the render policy (a tunnel has one key).
    options = [
        "BatchMode=yes", "IdentitiesOnly=yes", "IdentityAgent=none", "IdentityFile=none",
        f'IdentityFile="{adapted["keys"]["inspect"]}"', "CertificateFile=none",
        "PubkeyAuthentication=yes", "PreferredAuthentications=publickey",
        "PubkeyAcceptedAlgorithms=ssh-ed25519,rsa-sha2-512,rsa-sha2-256,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521",
        "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "GSSAPIAuthentication=no",
        "HostbasedAuthentication=no", "NumberOfPasswordPrompts=0", "StrictHostKeyChecking=yes",
        f'UserKnownHostsFile="{adapted["knownHosts"]}"', "GlobalKnownHostsFile=/dev/null",
        "KnownHostsCommand=none", "VerifyHostKeyDNS=no", "UpdateHostKeys=no", "CheckHostIP=no",
        "ProxyCommand=none", "ProxyJump=none", "CanonicalizeHostname=no", "PermitLocalCommand=no",
        "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=no", "Tunnel=no", "GatewayPorts=no",
        "ExitOnForwardFailure=yes", "RequestTTY=no", "StdinNull=yes", "ControlMaster=no",
        "ControlPath=none", "ControlPersist=no", "ConnectionAttempts=1", "ConnectTimeout=3",
        "ServerAliveInterval=3", "ServerAliveCountMax=1",
    ]
    return [remote_control.SSH, "-F", "/dev/null", "-N", "-T", "-n", "-v",
            *[part for option in options for part in ("-o", option)],
            "-L", f'127.0.0.1:{port}:127.0.0.1:{entry["comfyPort"]}',
            "-p", str(entry["port"]), "-l", entry["user"], entry["host"]]


class Tunnel:
    def __init__(self, entry, timeout=5):
        self.entry, self.timeout = entry, min(5, max(.05, timeout))
        self.process = None
        self.port = None
        self.sockets = []
        self.deadline = None

    def __enter__(self):
        self.deadline = time.monotonic() + self.timeout
        try:
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                self.port = reservation.getsockname()[1]
            self.process = subprocess.Popen(ssh_argv(self.entry, self.port), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LANG": "C"}, start_new_session=True)
            deadline, evidence = self.deadline, b""
            # The child must confirm its own bound listener after authentication.
            # Probing a port alone could mistake an unrelated local listener for SSH.
            wanted = f"Local forwarding listening on 127.0.0.1 port {self.port}.".encode()
            while time.monotonic() < deadline:
                self.alive()
                ready, _, _ = select.select([self.process.stderr], [], [], min(.05, max(0, deadline - time.monotonic())))
                if ready:
                    chunk = os.read(self.process.stderr.fileno(), 4096)
                    evidence += chunk
                    if not chunk or len(evidence) > 65536:
                        raise TransportError()
                    if wanted in evidence and b"Entering interactive session" in evidence:
                        self.alive()
                        return self
            raise TransportError()
        except Exception:
            self.__exit__(None, None, None)
            raise TransportError() from None

    def alive(self):
        if self.process is None or self.process.poll() is not None:
            raise TransportError()
        # Drain diagnostics without retaining or persisting server-controlled text.
        # Startup uses its own evidence read; later calls need not fill the pipe.

    def __exit__(self, *args):
        for sock in self.sockets:
            sock.close()
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
            self.process.wait(timeout=1)
            self.process.stderr.close()

    def request(self, path, payload=None, *, limit=4 * 1024 * 1024, timeout=3, sink=None):
        self.alive()
        timeout = min(timeout, self.deadline - time.monotonic())
        if timeout <= 0:
            raise TransportError()
        if not path.startswith("/") or any(c in path for c in "\r\n"):
            raise TransportError()
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        timer = None
        try:
            conn.connect()
            sock = conn.sock
            # A socket inactivity timeout alone does not bound slow-drip headers.
            def expire():
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            timer = threading.Timer(timeout, expire)
            timer.daemon = True
            timer.start()
            body = json.dumps(payload, allow_nan=False).encode() if payload is not None else None
            conn.request("POST" if payload is not None else "GET", path, body,
                         {"Content-Type": "application/json", "Connection": "close"})
            response = conn.getresponse()
            if response.status != 200 or response.getheader("Content-Encoding", "identity") != "identity":
                raise TransportError()
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdigit() or int(length) > limit):
                raise TransportError()
            size, chunks = 0, []
            while True:
                chunk = response.read1(min(65536, limit + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                if size > limit:
                    raise TransportError()
                if sink is None:
                    chunks.append(chunk)
                else:
                    sink.write(chunk)
            if length is not None and size != int(length):
                raise TransportError()
            self.alive()
            return (size if sink is not None else b"".join(chunks)), response.getheader("Content-Type", "").split(";")[0]
        except Exception:
            raise TransportError() from None
        finally:
            if timer:
                timer.cancel()
                timer.join(1)
            conn.close()

    def json(self, path, payload=None):
        data, mime = self.request(path, payload, timeout=self.timeout)
        if mime != "application/json":
            raise TransportError()
        try:
            return json.loads(data)
        except (ValueError, RecursionError):
            raise TransportError() from None

    def progress(self, request_id, prompt_id, nodes):
        """One short native WS sample. Queue/history remain completion authority."""
        self.alive()
        deadline = min(time.monotonic() + .25, self.deadline)
        if deadline <= time.monotonic():
            return []
        sock = None
        def read(count):
            data = b""
            while len(data) < count:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError()
                sock.settimeout(left)
                chunk = sock.recv(count - len(data))
                if not chunk:
                    raise EOFError()
                data += chunk
            return data
        try:
            # WS is optional telemetry. Connection refusal/timeout must have the
            # same polling fallback as a failed handshake or dropped stream.
            sock = socket.create_connection(("127.0.0.1", self.port), timeout=max(.001, deadline - time.monotonic()))
            self.sockets.append(sock)
            key = base64.b64encode(os.urandom(16)).decode()
            sock.sendall((f"GET /ws?clientId={request_id} HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n"
                          "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                          f"Sec-WebSocket-Key: {key}\r\n\r\n").encode())
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                header += read(1)
                if len(header) > 8192:
                    raise TransportError()
            lines = header.decode("ascii").split("\r\n")
            fields = {name.lower(): value.strip() for line in lines[1:] if ":" in line for name, value in [line.split(":", 1)]}
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if (lines[0].split()[1] != "101" or fields.get("sec-websocket-accept") != accept
                    or fields.get("upgrade", "").lower() != "websocket"):
                raise TransportError()
            progress, message, active = [], b"", None
            for _ in range(32):
                first, second = read(2)
                if first & 0x70 or second & 0x80:
                    raise TransportError()
                opcode, final, size = first & 15, bool(first & 128), second & 127
                if size == 126:
                    size = struct.unpack("!H", read(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", read(8))[0]
                if size > 65536 or len(message) + size > 65536:
                    raise TransportError()
                data = read(size)
                if opcode >= 8:
                    if not final or size > 125:
                        raise TransportError()
                    if opcode == 8:
                        break
                    if opcode == 9:
                        mask = os.urandom(4)
                        sock.sendall(bytes([0x8a, 0x80 | size]) + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(data)))
                    continue
                if opcode in (1, 2) and active is None:
                    active = opcode
                elif opcode != 0 or active is None:
                    raise TransportError()
                message += data
                if not final:
                    continue
                if active == 1:
                    event = json.loads(message)
                    detail = event.get("data", {})
                    if event.get("type") == "progress" and detail.get("prompt_id") == prompt_id:
                        value, maximum, node = detail.get("value"), detail.get("max"), detail.get("node")
                        if type(value) is int and type(maximum) is int and 0 <= value <= maximum <= 1000000 and maximum > 0 and node in nodes:
                            progress.append({"state": "running", "node": node, "value": value, "max": maximum})
                message, active = b"", None
            return progress
        except (TimeoutError, EOFError):
            return locals().get("progress", [])
        except Exception:
            return []
        finally:
            if sock is not None:
                sock.close()
                self.sockets.remove(sock)
