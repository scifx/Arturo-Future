#!/usr/bin/env python3
"""Tiny local HTTP server used to exercise `request.stream`.

Endpoints:
  /lines   - 5 chunked lines, 200ms apart
  /sse     - 4 server-sent events, 200ms apart, then [DONE]
  /big     - 20 lines, no delay
  /endless - never stops (for early-abandon tests)
"""
import socket, threading, time, sys


def chunk(s: str) -> bytes:
    b = s.encode()
    return f"{len(b):x}\r\n".encode() + b + b"\r\n"


def handle(conn):
    try:
        conn.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data:
            r = conn.recv(4096)
            if not r:
                return
            data += r
        path = data.split(b" ")[1].decode()

        hdr = (
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: {ct}\r\n"
            "Transfer-Encoding: chunked\r\n"
            "X-Test: arturo\r\n\r\n"
        )

        if path.startswith("/sse"):
            conn.sendall(hdr.format(ct="text/event-stream").encode())
            for i in range(1, 5):
                conn.sendall(chunk(f"event: token\ndata: tok{i}\nid: {i}\n\n"))
                time.sleep(0.2)
            conn.sendall(chunk("data: [DONE]\n\n"))
            conn.sendall(b"0\r\n\r\n")

        elif path.startswith("/lines"):
            conn.sendall(hdr.format(ct="text/plain").encode())
            for i in range(1, 6):
                conn.sendall(chunk(f"line{i}\n"))
                time.sleep(0.2)
            conn.sendall(b"0\r\n\r\n")

        elif path.startswith("/big"):
            conn.sendall(hdr.format(ct="text/plain").encode())
            for i in range(1, 21):
                conn.sendall(chunk(f"row{i}\n"))
            conn.sendall(b"0\r\n\r\n")

        elif path.startswith("/endless"):
            conn.sendall(hdr.format(ct="text/plain").encode())
            while True:
                conn.sendall(chunk("forever\n"))
                time.sleep(0.05)

        elif path.startswith("/multiline-sse"):
            conn.sendall(hdr.format(ct="text/event-stream").encode())
            conn.sendall(chunk(": a comment\n\n"))
            conn.sendall(chunk("data: part one\ndata: part two\n\n"))
            conn.sendall(b"0\r\n\r\n")

        else:
            conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18980
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)
    print(f"listening on {port}", flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
