#!/usr/bin/env python3
"""
PALEON SITE 7 — HOSTILE TEST TARGET — DO NOT USE FOR PRODUCTION

Localhost-only raw protocol backends used by Nginx stream ssl_preread on :443.

Port 9998: Malformed TLS — accept TCP, read a bounded ClientHello, emit
           deliberately malformed TLS bytes, close. Never HTTP.
Port 9999: Malformed HTTP — complete a real TLS handshake, read bounded HTTP
           request bytes, emit malformed HTTP on the TLS socket, close.
           SAFE-004 / SAFE-004-TLS.

Concurrency is bounded with a semaphore + thread pool (no unbounded
thread-per-connection). Idle connections are reaped.
"""

import json
import logging
import socket
import ssl
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Callable, Optional

HOST = "127.0.0.1"
PORT_TLS = 9998
PORT_HTTP = 9999
MAX_CONNECTIONS_PER_PORT = 10
IDLE_TIMEOUT = 30
READ_TIMEOUT = 5.0
MAX_READ_BYTES = 8192

CERT_FILE = "/etc/ssl/site7/site7.crt"
KEY_FILE = "/etc/ssl/site7/site7.key"

SENSITIVE_KEYS = (
    "cookie", "authorization", "password", "secret", "token",
    "api_key", "apikey", "api-key", "x-api-key", "credential",
)


class JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        skip = {
            "name", "msg", "args", "created", "filename", "funcName",
            "levelname", "levelno", "lineno", "module", "msecs", "message",
            "pathname", "process", "processName", "relativeCreated", "thread",
            "threadName", "exc_info", "exc_text", "stack_info",
        }
        for key, value in record.__dict__.items():
            if key in skip:
                continue
            if key.lower() not in SENSITIVE_KEYS:
                log_entry[key] = value
        return json.dumps(log_entry)


logger = logging.getLogger("paleon.site7.malformed")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)


class ConnectionManager:
    def __init__(self, max_connections: int = MAX_CONNECTIONS_PER_PORT, idle_timeout: int = IDLE_TIMEOUT):
        self.max_connections = max_connections
        self.idle_timeout = idle_timeout
        self._lock = threading.Lock()
        self._connections = {}
        self._conn_counter = 0

    def register(self, sock: socket.socket) -> Optional[int]:
        with self._lock:
            if len(self._connections) >= self.max_connections:
                return None
            self._conn_counter += 1
            conn_id = self._conn_counter
            self._connections[conn_id] = {
                "socket": sock,
                "last_activity": time.time(),
            }
            return conn_id

    def unregister(self, conn_id: int):
        with self._lock:
            self._connections.pop(conn_id, None)

    def update_activity(self, conn_id: int):
        with self._lock:
            if conn_id in self._connections:
                self._connections[conn_id]["last_activity"] = time.time()

    def check_idle(self) -> list:
        now = time.time()
        with self._lock:
            return [
                conn_id for conn_id, info in self._connections.items()
                if now - info["last_activity"] > self.idle_timeout
            ]

    def close_id(self, conn_id: int):
        with self._lock:
            info = self._connections.pop(conn_id, None)
        if not info:
            return
        sock = info["socket"]
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass


tls_connections = ConnectionManager()
http_connections = ConnectionManager()


def read_until(sock, end_marker: bytes, max_bytes: int = MAX_READ_BYTES, timeout: float = READ_TIMEOUT) -> bytes:
    """Fragmentation-tolerant bounded read. Does not assume recv() returns N bytes."""
    sock.settimeout(timeout)
    buf = bytearray()
    deadline = time.time() + timeout
    while len(buf) < max_bytes:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise socket.timeout("Read timed out")
        sock.settimeout(remaining)
        chunk = sock.recv(min(1024, max_bytes - len(buf)))
        if not chunk:
            break
        buf.extend(chunk)
        if end_marker and end_marker in buf:
            break
        if len(buf) >= 5 and buf[0] == 0x16:
            record_len = (buf[3] << 8) | buf[4]
            if record_len > max_bytes:
                break
            if len(buf) >= 5 + record_len:
                break
    return bytes(buf)


GARBLED_SERVER_HELLO = (
    b"\x16"           # TLS Record Type: Handshake
    b"\x03\x03"       # TLS Version: 1.2
    b"\x00\x10"       # Record Length: 16
    b"\x02"           # Handshake Type: ServerHello
    b"\x00\x00\x0c"   # Handshake Length: 12
    b"\x03\x03"       # Version: TLS 1.2
    b"\xFF\xFE\xFD\xFC\xFB\xFA\xF9\xF8\xF7\xF6"
)


def handle_raw_tls(conn: socket.socket, addr: tuple, conn_id: int):
    try:
        read_until(conn, b"", max_bytes=MAX_READ_BYTES, timeout=READ_TIMEOUT)
        tls_connections.update_activity(conn_id)
        conn.sendall(GARBLED_SERVER_HELLO)
        tls_connections.update_activity(conn_id)
        logger.info("raw_tls_garbled_sent", extra={"connection_id": conn_id, "resilience_id": "SAFE-004-TLS"})
    except Exception as e:
        logger.warning("raw_tls_error", extra={"error": str(e), "connection_id": conn_id})
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass
        tls_connections.unregister(conn_id)


def handle_tls_http(conn: socket.socket, addr: tuple, conn_id: int):
    tls_conn = None
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT_FILE, KEY_FILE)
        conn.settimeout(READ_TIMEOUT)
        tls_conn = ctx.wrap_socket(conn, server_side=True)

        data = read_until(tls_conn, b"\r\n\r\n", max_bytes=MAX_READ_BYTES, timeout=READ_TIMEOUT)
        http_connections.update_activity(conn_id)
        request_str = data.decode("latin1", errors="ignore")

        if "/malformed/chunked" in request_str:
            payload = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/plain\r\n"
                b"Transfer-Encoding: chunked\r\n\r\n"
                b"5\r\nHELLO\r\n"
                b"GARBAGE\r\n"
                b"0\r\n\r\n"
            )
            endpoint = "chunked"
        elif "/malformed/banner" in request_str:
            payload = (
                b"HTTP/1.1 200 OK\r\n"
                b"X-Control-Header: \x00\x01\x02\x03\r\n"
                b"Content-Length: 14\r\n\r\n"
                b"MALFORMED_HEADER"
            )
            endpoint = "banner"
        else:
            payload = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/plain\r\n"
                b"Content-Length: 13\r\n\r\n"
                b"MALFORMED HTTP"
            )
            endpoint = "default"

        tls_conn.sendall(payload)
        http_connections.update_activity(conn_id)
        logger.info(
            "tls_http_malformed_sent",
            extra={"connection_id": conn_id, "resilience_id": "SAFE-004", "endpoint": endpoint},
        )
        try:
            tls_conn.unwrap()
        except Exception:
            pass
    except Exception as e:
        logger.warning("tls_http_error", extra={"error": str(e), "connection_id": conn_id})
    finally:
        if tls_conn is not None:
            try:
                tls_conn.close()
            except OSError:
                pass
        try:
            conn.close()
        except OSError:
            pass
        http_connections.unregister(conn_id)


def idle_reaper():
    while True:
        time.sleep(5)
        for mgr in (tls_connections, http_connections):
            for conn_id in mgr.check_idle():
                mgr.close_id(conn_id)
                logger.info("idle_connection_closed", extra={"connection_id": conn_id})


def run_server(port: int, handler_func: Callable, manager: ConnectionManager, pool: ThreadPoolExecutor):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    semaphore = threading.BoundedSemaphore(MAX_CONNECTIONS_PER_PORT)
    try:
        server.bind((HOST, port))
        server.listen(MAX_CONNECTIONS_PER_PORT)
        logger.info("server_started", extra={"port": port})

        while True:
            try:
                conn, addr = server.accept()
                if not semaphore.acquire(blocking=False):
                    try:
                        conn.close()
                    except OSError:
                        pass
                    continue

                conn_id = manager.register(conn)
                if conn_id is None:
                    semaphore.release()
                    try:
                        conn.close()
                    except OSError:
                        pass
                    continue

                def _run(c=conn, a=addr, cid=conn_id, sem=semaphore):
                    try:
                        handler_func(c, a, cid)
                    finally:
                        sem.release()

                pool.submit(_run)
            except Exception as e:
                logger.error("accept_error", extra={"port": port, "error": str(e)})
    finally:
        server.close()


def main():
    reaper_thread = threading.Thread(target=idle_reaper, daemon=True, name="idle-reaper")
    reaper_thread.start()

    tls_pool = ThreadPoolExecutor(max_workers=MAX_CONNECTIONS_PER_PORT, thread_name_prefix="malformed-tls-")
    http_pool = ThreadPoolExecutor(max_workers=MAX_CONNECTIONS_PER_PORT, thread_name_prefix="malformed-http-")

    tls_thread = threading.Thread(
        target=run_server,
        args=(PORT_TLS, handle_raw_tls, tls_connections, tls_pool),
        daemon=True,
        name="listen-9998",
    )
    http_thread = threading.Thread(
        target=run_server,
        args=(PORT_HTTP, handle_tls_http, http_connections, http_pool),
        daemon=True,
        name="listen-9999",
    )
    tls_thread.start()
    http_thread.start()

    logger.info("both_servers_started")
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        tls_pool.shutdown(wait=False, cancel_futures=True)
        http_pool.shutdown(wait=False, cancel_futures=True)


if __name__ == "__main__":
    main()
