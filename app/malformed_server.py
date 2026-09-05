#!/usr/bin/env python3
"""
PALEON SITE 7 — HOSTILE TEST TARGET — DO NOT USE FOR PRODUCTION

Separate server for malformed HTTP responses on localhost:9999.
Serves invalid chunked encoding and junk HTTP banners.
Connection cap: 10 concurrent. Auto-terminates idle connections after 30s.
"""

import socket
import threading
import time
import logging
import json
from datetime import datetime, timezone
from typing import Optional

# ============================================================================
# Configuration
# ============================================================================
HOST = '127.0.0.1'
PORT = 9999
MAX_CONNECTIONS = 10
IDLE_TIMEOUT = 30  # seconds

# ============================================================================
# Structured Logging
# ============================================================================
class JSONFormatter(logging.Formatter):
    """JSON log formatter that excludes sensitive data."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        for key, value in record.__dict__.items():
            if key not in ('name', 'msg', 'args', 'created', 'filename', 'funcName',
                           'levelname', 'levelno', 'lineno', 'module', 'msecs',
                           'message', 'msg', 'name', 'pathname', 'process',
                           'processName', 'relativeCreated', 'thread', 'threadName',
                           'exc_info', 'exc_text', 'stack_info'):
                if key.lower() not in ('cookie', 'authorization', 'password', 'secret',
                                       'token', 'api_key', 'apikey', 'credential'):
                    log_entry[key] = value

        return json.dumps(log_entry)


logger = logging.getLogger("paleon.site7.malformed")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)

# ============================================================================
# Connection Tracking
# ============================================================================
class ConnectionManager:
    """Manages active connections with limits and idle timeout."""

    def __init__(self, max_connections: int = MAX_CONNECTIONS, idle_timeout: int = IDLE_TIMEOUT):
        self.max_connections = max_connections
        self.idle_timeout = idle_timeout
        self._lock = threading.Lock()
        self._connections = {}  # conn_id -> {'socket': sock, 'last_activity': time, 'thread': thread}
        self._conn_counter = 0

    def register(self, sock: socket.socket, thread: threading.Thread) -> Optional[int]:
        """Register a new connection. Returns connection ID or None if at capacity."""
        with self._lock:
            if len(self._connections) >= self.max_connections:
                return None
            self._conn_counter += 1
            conn_id = self._conn_counter
            self._connections[conn_id] = {
                'socket': sock,
                'last_activity': time.time(),
                'thread': thread
            }
            return conn_id

    def unregister(self, conn_id: int):
        """Unregister a connection."""
        with self._lock:
            self._connections.pop(conn_id, None)

    def update_activity(self, conn_id: int):
        """Update last activity timestamp."""
        with self._lock:
            if conn_id in self._connections:
                self._connections[conn_id]['last_activity'] = time.time()

    def check_idle(self) -> list:
        """Check for idle connections. Returns list of connection IDs to close."""
        now = time.time()
        with self._lock:
            idle_ids = [
                conn_id for conn_id, info in self._connections.items()
                if now - info['last_activity'] > self.idle_timeout
            ]
            return idle_ids


connection_manager = ConnectionManager()

# ============================================================================
# Response Generators
# ============================================================================
def generate_invalid_chunked() -> bytes:
    """Generate invalid chunked encoding response."""
    # Bad chunked encoding examples:
    # - Invalid hex length
    # - Missing chunk data
    # - Truncated terminator
    return (
        b"HTTP/1.1 200 OK\r\n"
        b"Transfer-Encoding: chunked\r\n"
        b"Content-Type: text/plain\r\n"
        b"X-Test: malformed-chunked\r\n"
        b"\r\n"
        b"5\r\n"           # Valid chunk length
        b"hello\r\n"       # Valid chunk data
        b"GARBAGE\r\n"     # INVALID: not hex
        b"3\r\n"           # Valid chunk length
        b"foo\r\n"         # Valid chunk data
        b"\r\n"            # INVALID: missing chunk data for zero-length
        b"0\r\n"           # Terminator
        b"\r\n"            # Terminator CRLF
    )


def generate_junk_banner() -> bytes:
    """Generate junk HTTP banner response."""
    return (
        b"HTTP/1.1 200 OK\r\n"
        b"Server: Paleon-Hostile-Malformed/7.0\r\n"
        b"X-Junk-Banner: \x00\x01\x02\x03\xFF\xFE\xFD\xFC\r\n"
        b"Content-Type: text/plain\r\n"
        b"Connection: close\r\n"
        b"\r\n"
        b"This is a junk HTTP banner response.\x00\x01\x02\x03"
        b"\xFF\xFE\xFD\xFC\xFB\xFA\xF9\r\n"
        b"Extra garbage: \x80\x81\x82\x83\x84\x85\r\n"
    )


# ============================================================================
# Connection Handler
# ============================================================================
def handle_connection(conn: socket.socket, addr: tuple, conn_id: int):
    """Handle a single client connection."""
    client_ip, client_port = addr
    logger.info("connection_accepted", extra={
        "connection_id": conn_id,
        "client_ip": client_ip,
        "client_port": client_port,
        "active_connections": len(connection_manager._connections)
    })

    conn.settimeout(5.0)  # Initial read timeout

    try:
        # Read request (we don't care about content, just log it)
        request_data = b""
        while True:
            try:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                request_data += chunk
                connection_manager.update_activity(conn_id)
                # Check for end of headers
                if b"\r\n\r\n" in request_data:
                    break
            except socket.timeout:
                break
            except Exception:
                break

        # Log the request (truncated, no sensitive data)
        request_preview = request_data[:200].decode('utf-8', errors='replace')
        logger.info("request_received", extra={
            "connection_id": conn_id,
            "client_ip": client_ip,
            "request_preview": request_preview
        })

        # Determine response type based on request path
        response = generate_invalid_chunked()
        if b"/malformed/banner" in request_data or b"/banner" in request_data:
            response = generate_junk_banner()

        # Send response
        conn.sendall(response)
        connection_manager.update_activity(conn_id)

        logger.info("response_sent", extra={
            "connection_id": conn_id,
            "client_ip": client_ip,
            "response_type": "junk_banner" if b"/banner" in request_data else "invalid_chunked",
            "response_size": len(response)
        })

    except Exception as e:
        logger.warning("connection_error", extra={
            "connection_id": conn_id,
            "client_ip": client_ip,
            "error": str(e)
        })
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass
        connection_manager.unregister(conn_id)
        logger.info("connection_closed", extra={
            "connection_id": conn_id,
            "client_ip": client_ip,
            "active_connections": len(connection_manager._connections)
        })


# ============================================================================
# Idle Connection Reaper
# ============================================================================
def idle_reaper():
    """Background thread to close idle connections."""
    while True:
        time.sleep(5)
        idle_ids = connection_manager.check_idle()
        for conn_id in idle_ids:
            with connection_manager._lock:
                if conn_id in connection_manager._connections:
                    info = connection_manager._connections[conn_id]
                    sock = info['socket']
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                        sock.close()
                    except Exception:
                        pass
                    connection_manager.unregister(conn_id)
                    logger.info("idle_connection_closed", extra={
                        "connection_id": conn_id
                    })


# ============================================================================
# Main Server
# ============================================================================
def main():
    """Run the malformed HTTP server."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        server.bind((HOST, PORT))
        server.listen(MAX_CONNECTIONS)
        logger.info("server_started", extra={
            "host": HOST,
            "port": PORT,
            "max_connections": MAX_CONNECTIONS,
            "idle_timeout": IDLE_TIMEOUT
        })

        # Start idle reaper thread
        reaper_thread = threading.Thread(target=idle_reaper, daemon=True)
        reaper_thread.start()

        print(f"Malformed HTTP server listening on {HOST}:{PORT}")
        print(f"Max connections: {MAX_CONNECTIONS}, Idle timeout: {IDLE_TIMEOUT}s")
        print("Endpoints:")
        print("  GET /malformed/chunked  - Invalid chunked encoding")
        print("  GET /malformed/banner   - Junk HTTP banner")

        while True:
            try:
                conn, addr = server.accept()

                # Check connection limit
                conn_id = connection_manager.register(conn, None)
                if conn_id is None:
                    # At capacity - reject immediately
                    logger.warning("connection_rejected_capacity", extra={
                        "client_ip": addr[0],
                        "active_connections": len(connection_manager._connections)
                    })
                    try:
                        conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n")
                    except Exception:
                        pass
                    conn.close()
                    continue

                # Handle in new thread
                thread = threading.Thread(target=handle_connection, args=(conn, addr, conn_id), daemon=True)
                thread.start()

                # Update thread reference
                with connection_manager._lock:
                    if conn_id in connection_manager._connections:
                        connection_manager._connections[conn_id]['thread'] = thread

            except KeyboardInterrupt:
                logger.info("server_shutdown", extra={"reason": "keyboard_interrupt"})
                break
            except Exception as e:
                logger.error("server_error", extra={"error": str(e)})

    finally:
        server.close()
        logger.info("server_stopped")


if __name__ == '__main__':
    main()