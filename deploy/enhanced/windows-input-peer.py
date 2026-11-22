# SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
# SPDX-License-Identifier: MIT
"""A disposable loopback peer for the released Windows receiving core."""
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import sys
import time


def exact(conn, length):
    received = bytearray()
    while len(received) < length:
        chunk = conn.recv(length - len(received))
        if not chunk:
            raise EOFError
        received.extend(chunk)
    return bytes(received)


def receive(conn):
    size, = struct.unpack("!I", exact(conn, 4))
    if size > 32768:
        raise ValueError("Unexpected fixture packet size")
    return exact(conn, size)


def send(conn, message, layout="", *values):
    packet = message + struct.pack("!" + layout, *values)
    conn.sendall(struct.pack("!I", len(packet)) + packet)


def run(conn, root):
    send(conn, b"Barrier", "HH", 1, 7)
    hello = receive(conn)
    assert hello.startswith(b"Barrier"), hello[:7]
    send(conn, b"QINF")
    for _ in range(16):
        packet = receive(conn)
        if packet.startswith(b"DINF"):
            origin_x, origin_y, width, height, *_ = struct.unpack("!7h", packet[4:])
            break
    else:
        raise ValueError("Deskflow did not report the native desktop geometry")
    send(conn, b"CIAK")
    send(conn, b"DSOP", "I", 0)
    (root / "connected").touch()

    target = root / "target.json"
    deadline = time.monotonic() + 30
    while not target.exists():
        if time.monotonic() > deadline:
            raise TimeoutError("Isolated input target did not open")
        send(conn, b"CALV")
        time.sleep(0.3)
    x, y = json.loads(target.read_text(encoding="utf-8"))
    assert origin_x < x - 5 < x < origin_x + width and origin_y < y < origin_y + height
    send(conn, b"CINN", "hhIH", x - 5, y, 1, 0)
    send(conn, b"DMMV", "hh", x, y)
    time.sleep(0.15)
    send(conn, b"DMDN", "B", 1)
    send(conn, b"DMUP", "B", 1)
    time.sleep(0.15)
    for index, char in enumerate("deskflow", start=1):
        send(conn, b"DKDN", "HHH", ord(char), 0, index)
        send(conn, b"DKUP", "HHH", ord(char), 0, index)
        time.sleep(0.05)
    send(conn, b"COUT")
    (root / "input-sent").touch()
    time.sleep(2)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Run only on the disposable hosted test VM")
    root = Path(sys.argv[1])
    client_pem = Path(sys.argv[2]).read_text(encoding="utf-8")
    client_pem = client_pem[client_pem.index("-----BEGIN CERTIFICATE-----"):]
    client_pem = client_pem[:client_pem.index("-----END CERTIFICATE-----") + len("-----END CERTIFICATE-----")]
    expected = hashlib.sha256(ssl.PEM_cert_to_DER_cert(client_pem)).digest()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(root / "peer.pem", root / "peer.key")
    tls.load_verify_locations(cadata=client_pem)
    tls.verify_mode = ssl.CERT_REQUIRED
    with socket.create_server(("127.0.0.1", 34800)) as listener:
        listener.settimeout(45)
        (root / "listening").touch()
        for attempt in range(2):
            raw, local = listener.accept()
            assert local[0] == "127.0.0.1"
            with raw, tls.wrap_socket(raw, server_side=True) as conn:
                conn.settimeout(15)
                assert hashlib.sha256(conn.getpeercert(binary_form=True)).digest() == expected
                try:
                    run(conn, root)
                    return
                except (ssl.SSLError, EOFError, ConnectionResetError):
                    if attempt or (root / "connected").exists():
                        raise
                    print("Client declined the first connection pending identity review", flush=True)
        raise AssertionError("Expected a separate verified TLS connection")


if __name__ == "__main__":
    main()
