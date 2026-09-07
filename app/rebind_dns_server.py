#!/usr/bin/env python3
"""
PALEON SITE 7 — DNS Rebinding Test Server (SAFE-007)

Listens on 0.0.0.0:53 TCP and UDP. Authoritative only for
rebind-test.paleon-lab-hostile.com. Recursion is never offered (RA=0, AA=1
on answers for the test name).

A query #1 from a given client IP -> Site 7 EIP (SITE7_EIP, required)
A query #2+ from that client IP -> 192.168.1.1
TTL = 0
Only A queries for the intended hostname advance state.

SITE7_EIP must be injected at deploy time. Missing/invalid configuration
is a hard failure (no IMDS, no third-party IP discovery, no example.com).
"""

import ipaddress
import json
import os
import socket
import struct
import sys
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

DNS_HOST = "0.0.0.0"
DNS_PORT = 53
PRIVATE_IP = "192.168.1.1"
REBIND_HOSTNAME = "rebind-test.paleon-lab-hostile.com"
STATE_FILE = "/var/lib/site7/rebind-state.json"
MAX_QUERIES_PER_CLIENT = 100
MAX_CLIENTS = 100
MAX_WORKERS = 10
MAX_DNS_MESSAGE = 4096
UDP_RECV = 512


def get_public_ip():
    """Public EIP from deployment configuration only."""
    public_ip = os.environ.get("SITE7_EIP", "").strip()
    if not public_ip:
        print("[REBIND] FATAL: SITE7_EIP is not set. Refusing to start with a guessed public IP.", file=sys.stderr)
        sys.exit(1)
    try:
        parsed = ipaddress.ip_address(public_ip)
    except ValueError:
        print(f"[REBIND] FATAL: SITE7_EIP is not a valid IP address: {public_ip!r}", file=sys.stderr)
        sys.exit(1)
    if parsed.is_unspecified or parsed.version != 4:
        print(f"[REBIND] FATAL: SITE7_EIP must be a unicast IPv4 address: {public_ip!r}", file=sys.stderr)
        sys.exit(1)
    print(f"[REBIND] Using public IP from SITE7_EIP: {public_ip}")
    return public_ip


PUBLIC_IP = None


class DNSRebindServer:
    def __init__(self, require_eip: bool = True):
        global PUBLIC_IP
        if require_eip:
            PUBLIC_IP = get_public_ip()
        self.client_counts = OrderedDict()
        self.total_a_queries = 0
        self.state_file = STATE_FILE
        self.lock = threading.Lock()
        self.load_state()
        self.udp_executor = ThreadPoolExecutor(max_workers=MAX_WORKERS, thread_name_prefix="dns-udp-")
        self.tcp_executor = ThreadPoolExecutor(max_workers=MAX_WORKERS, thread_name_prefix="dns-tcp-")
        self.tcp_semaphore = threading.BoundedSemaphore(MAX_WORKERS)
        self.udp_semaphore = threading.BoundedSemaphore(MAX_WORKERS)

    def load_state(self):
        try:
            if os.path.exists(self.state_file):
                with open(self.state_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if int(data.get("query_count", 0) or 0) == 0 and not data.get("clients"):
                    self.client_counts = OrderedDict()
                    self.total_a_queries = 0
                    print("[REBIND] Loaded reset state")
                    return
                clients = data.get("clients") or {}
                self.client_counts = OrderedDict((k, int(v)) for k, v in list(clients.items())[-MAX_CLIENTS:])
                self.total_a_queries = int(data.get("total_a_queries", 0) or 0)
                print(f"[REBIND] Loaded state: clients={len(self.client_counts)} total_a={self.total_a_queries}")
        except (json.JSONDecodeError, OSError, TypeError, ValueError) as e:
            print(f"[REBIND] Could not load state: {e}, using defaults")
            self.client_counts = OrderedDict()
            self.total_a_queries = 0

    def save_state(self):
        try:
            os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
            payload = {
                "query_count": self.total_a_queries,
                "total_a_queries": self.total_a_queries,
                "state": "mixed" if self.client_counts else "public",
                "clients": dict(self.client_counts),
                "last_query": time.time(),
            }
            tmp = self.state_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(tmp, self.state_file)
        except OSError as e:
            print(f"[REBIND] Could not save state: {e}")

    def reset(self):
        with self.lock:
            self.client_counts = OrderedDict()
            self.total_a_queries = 0
            self.save_state()
            print("[REBIND] State reset to initial conditions")

    def get_answer_ip(self, client_ip: str) -> str:
        with self.lock:
            if client_ip not in self.client_counts and len(self.client_counts) >= MAX_CLIENTS:
                self.client_counts.popitem(last=False)
            count = int(self.client_counts.get(client_ip, 0))
            # Contract: query #1 (count == 0) -> public EIP; every subsequent
            # query -> private 192.168.1.1. The per-client counter is CAPPED at
            # MAX_QUERIES_PER_CLIENT, never wrapped, so query #101+ stays private.
            # A client can never be handed the public IP again after its first query.
            answer = PUBLIC_IP if count == 0 else PRIVATE_IP
            self.client_counts[client_ip] = min(count + 1, MAX_QUERIES_PER_CLIENT)
            self.client_counts.move_to_end(client_ip)
            self.total_a_queries += 1
            self.save_state()
            print(f"[REBIND] {client_ip} A query #{count + 1} -> {answer} (SAFE-007)")
            return answer

    def parse_dns_query(self, data: bytes):
        try:
            if len(data) < 12 or len(data) > MAX_DNS_MESSAGE:
                return None
            txn_id = struct.unpack("!H", data[0:2])[0]
            offset = 12
            qname_parts = []
            hops = 0
            while offset < len(data) and hops < 128:
                hops += 1
                length = data[offset]
                if length == 0:
                    offset += 1
                    break
                if length & 0xC0 == 0xC0:
                    return None
                offset += 1
                if offset + length > len(data):
                    return None
                qname_parts.append(data[offset:offset + length].decode("ascii", errors="strict"))
                offset += length
            qname = ".".join(qname_parts).rstrip(".").lower()
            if offset + 4 > len(data):
                return None
            qtype, qclass = struct.unpack("!HH", data[offset:offset + 4])
            return (txn_id, qname, qtype, qclass)
        except Exception as e:
            print(f"[REBIND] Parse error: {e}")
            return None

    def build_header(self, txn_id, flags, qdcount, ancount):
        return struct.pack("!HHHHHH", txn_id, flags, qdcount, ancount, 0, 0)

    def encode_name(self, query_name: str) -> bytes:
        out = b""
        for part in query_name.split("."):
            label = part.encode("ascii")
            if len(label) > 63:
                raise ValueError("label too long")
            out += bytes([len(label)]) + label
        return out + b"\x00"

    def build_dns_response(self, txn_id, query_name, answer_ip):
        flags = 0x8400  # QR=1 AA=1 RA=0 RD=0
        header = self.build_header(txn_id, flags, 1, 1)
        question = self.encode_name(query_name) + struct.pack("!HH", 1, 1)
        ip_bytes = socket.inet_aton(answer_ip)
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + ip_bytes
        return header + question + answer

    def build_refused(self, txn_id):
        # QR=1, AA=0, RA=0, RCODE=REFUSED (5)
        return self.build_header(txn_id, 0x8005, 0, 0)

    def build_no_data(self, txn_id, query_name, qtype):
        flags = 0x8400
        header = self.build_header(txn_id, flags, 1, 0)
        question = self.encode_name(query_name) + struct.pack("!HH", qtype, 1)
        return header + question

    def is_test_name(self, qname: str) -> bool:
        return qname.rstrip(".").lower() == REBIND_HOSTNAME

    def handle_query_bytes(self, data: bytes, client_ip: str):
        parsed = self.parse_dns_query(data)
        if not parsed:
            return None
        txn_id, qname, qtype, qclass = parsed
        if qclass != 1:
            return self.build_refused(txn_id)
        if not self.is_test_name(qname):
            return self.build_refused(txn_id)
        if qtype != 1:
            return self.build_no_data(txn_id, qname, qtype)
        answer_ip = self.get_answer_ip(client_ip)
        return self.build_dns_response(txn_id, qname, answer_ip)

    def handle_udp_query(self, data, addr, sock):
        try:
            if len(data) > UDP_RECV:
                return
            response = self.handle_query_bytes(data, addr[0])
            if response:
                sock.sendto(response, addr)
        except Exception as e:
            print(f"[REBIND] UDP handle error: {e}")

    def recv_exact(self, conn, n: int, timeout: float = 2.0) -> bytes:
        conn.settimeout(timeout)
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk:
                break
            buf += chunk
        return buf

    def handle_tcp_conn(self, conn, addr):
        try:
            conn.settimeout(2.0)
            length_bytes = self.recv_exact(conn, 2)
            if len(length_bytes) != 2:
                return
            length = struct.unpack("!H", length_bytes)[0]
            if length == 0 or length > MAX_DNS_MESSAGE:
                return
            data = self.recv_exact(conn, length)
            if len(data) != length:
                return
            response = self.handle_query_bytes(data, addr[0])
            if response:
                conn.sendall(struct.pack("!H", len(response)) + response)
        except Exception as e:
            print(f"[REBIND] TCP Connection Error: {e}")
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def run_udp(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((DNS_HOST, DNS_PORT))
        print(f"[REBIND] UDP Server listening on {DNS_HOST}:{DNS_PORT}")
        try:
            while True:
                try:
                    data, addr = sock.recvfrom(UDP_RECV)
                    if not self.udp_semaphore.acquire(blocking=False):
                        continue

                    def _run(d=data, a=addr):
                        try:
                            self.handle_udp_query(d, a, sock)
                        finally:
                            self.udp_semaphore.release()

                    self.udp_executor.submit(_run)
                except Exception as e:
                    print(f"[REBIND] UDP Error: {e}")
        finally:
            sock.close()
            self.udp_executor.shutdown(wait=False)

    def run_tcp(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((DNS_HOST, DNS_PORT))
        sock.listen(MAX_WORKERS)
        print(f"[REBIND] TCP Server listening on {DNS_HOST}:{DNS_PORT}")
        try:
            while True:
                conn, addr = sock.accept()
                if not self.tcp_semaphore.acquire(blocking=False):
                    try:
                        conn.close()
                    except OSError:
                        pass
                    continue

                def _run(c=conn, a=addr):
                    try:
                        self.handle_tcp_conn(c, a)
                    finally:
                        self.tcp_semaphore.release()

                self.tcp_executor.submit(_run)
        finally:
            sock.close()
            self.tcp_executor.shutdown(wait=False)

    def run(self):
        print("[REBIND] Starting DNS rebinding server")
        print(f"[REBIND] Public IP: {PUBLIC_IP}")
        print(f"[REBIND] Private IP: {PRIVATE_IP}")
        print(f"[REBIND] Test hostname: {REBIND_HOSTNAME}")
        print(f"[REBIND] State file: {self.state_file}")

        udp_thread = threading.Thread(target=self.run_udp, daemon=True, name="dns-udp-listen")
        tcp_thread = threading.Thread(target=self.run_tcp, daemon=True, name="dns-tcp-listen")
        udp_thread.start()
        tcp_thread.start()
        try:
            while True:
                time.sleep(60)
        except KeyboardInterrupt:
            print("\n[REBIND] Shutting down")
            self.udp_executor.shutdown(wait=False)
            self.tcp_executor.shutdown(wait=False)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "reset":
        server = DNSRebindServer(require_eip=False)
        server.reset()
        print("[REBIND] Reset complete")
        sys.exit(0)
    server = DNSRebindServer(require_eip=True)
    server.run()


if __name__ == "__main__":
    main()
