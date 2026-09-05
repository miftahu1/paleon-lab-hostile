#!/usr/bin/env python3
"""
PALEON SITE 7 — DNS Rebinding Test Server
Listens on localhost:5353 (UDP) for authoritative DNS queries.

Behavior:
- First query: returns public test IP (93.184.216.34)
- Second query: returns private IP (192.168.1.1)
- TTL: 0 (forces re-resolution)
- Logs each query with sequence number
- Has reset mechanism to restore initial state

This server does NOT perform any outbound network calls.
"""

import socket
import struct
import threading
import json
import os
import sys
import time
from pathlib import Path

# Configuration
DNS_HOST = "127.0.0.1"
DNS_PORT = 5353
PUBLIC_IP = "93.184.216.34"  # Documentation/test address
PRIVATE_IP = "192.168.1.1"
REBIND_HOSTNAME = "rebind-test.paleon-lab-hostile.com"
STATE_FILE = "/var/lib/site7/rebind-state.json"
MAX_QUERIES = 100  # Safety limit

class DNSRebindServer:
    def __init__(self):
        self.query_count = 0
        self.state_file = STATE_FILE
        self.lock = threading.Lock()
        self.load_state()

    def load_state(self):
        """Load query count from state file if it exists."""
        try:
            if os.path.exists(self.state_file):
                with open(self.state_file, 'r') as f:
                    data = json.load(f)
                    self.query_count = data.get('query_count', 0)
                print(f"[REBIND] Loaded state: query_count={self.query_count}")
        except (json.JSONDecodeError, IOError) as e:
            print(f"[REBIND] Could not load state: {e}, using defaults")
            self.query_count = 0

    def save_state(self):
        """Save query count to state file."""
        try:
            os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
            with open(self.state_file, 'w') as f:
                json.dump({
                    'query_count': self.query_count,
                    'state': 'private' if self.query_count > 0 else 'public',
                    'last_query': time.time()
                }, f)
        except IOError as e:
            print(f"[REBIND] Could not save state: {e}")

    def reset(self):
        """Reset state to initial conditions."""
        with self.lock:
            self.query_count = 0
            self.save_state()
            print("[REBIND] State reset to initial conditions")

    def get_answer_ip(self):
        """Return appropriate IP based on query count."""
        with self.lock:
            if self.query_count == 0:
                self.query_count += 1
                self.save_state()
                print(f"[REBIND] Query #{self.query_count}: returning PUBLIC {PUBLIC_IP}")
                return PUBLIC_IP
            else:
                self.query_count += 1
                if self.query_count > MAX_QUERIES:
                    self.reset()
                    return PUBLIC_IP
                self.save_state()
                print(f"[REBIND] Query #{self.query_count}: returning PRIVATE {PRIVATE_IP}")
                return PRIVATE_IP

    def parse_dns_query(self, data):
        """Parse incoming DNS query and extract query name."""
        try:
            # Parse header (first 12 bytes)
            if len(data) < 12:
                return None

            # Transaction ID
            txn_id = struct.unpack('!H', data[0:2])[0]

            # Parse question section
            offset = 12
            qname_parts = []

            while offset < len(data):
                length = data[offset]
                if length == 0:
                    offset += 1
                    break
                offset += 1
                if offset + length > len(data):
                    return None
                qname_parts.append(data[offset:offset + length].decode('ascii', errors='ignore'))
                offset += length

            qname = '.'.join(qname_parts)
            return (txn_id, qname)
        except Exception as e:
            print(f"[REBIND] Parse error: {e}")
            return None

    def build_dns_response(self, txn_id, query_name, answer_ip):
        """Build DNS response with A record pointing to answer_ip."""
        # Response header
        flags = 0x8180  # Standard response, no error
        qdcount = 1
        ancount = 1
        nscount = 0
        arcount = 0

        header = struct.pack('!HHHHHH', txn_id, flags, qdcount, ancount, nscount, arcount)

        # Question section (copy of query)
        question = b''
        for part in query_name.split('.'):
            question += bytes([len(part)]) + part.encode('ascii')
        question += b'\x00'  # Root
        question += struct.pack('!HH', 1, 1)  # Type A, Class IN

        # Answer section
        answer = b''
        answer += b'\xc0\x0c'  # Pointer to offset 12 (query name)
        answer += struct.pack('!HH', 1, 1)  # Type A, Class IN
        answer += struct.pack('!I', 0)  # TTL: 0 (forces re-resolution)
        answer += struct.pack('!H', 4)  # RDLENGTH: 4 bytes

        # Convert IP to bytes
        ip_parts = answer_ip.split('.')
        ip_bytes = bytes([int(p) for p in ip_parts])
        answer += ip_bytes

        return header + question + answer

    def handle_query(self, data, addr, sock):
        """Handle a single DNS query."""
        parsed = self.parse_dns_query(data)
        if not parsed:
            print(f"[REBIND] Invalid query from {addr}")
            return

        txn_id, qname = parsed
        print(f"[REBIND] Query from {addr}: {qname}")

        # Only respond to our test hostname
        if REBIND_HOSTNAME not in qname:
            print(f"[REBIND] Ignoring query for {qname} (not our test hostname)")
            return

        # Get the appropriate answer
        answer_ip = self.get_answer_ip()

        # Build and send response
        response = self.build_dns_response(txn_id, qname, answer_ip)
        sock.sendto(response, addr)
        print(f"[REBIND] Sent response: {qname} -> {answer_ip}")

    def run(self):
        """Start the DNS server."""
        print(f"[REBIND] Starting DNS rebinding server on {DNS_HOST}:{DNS_PORT}")
        print(f"[REBIND] Public IP: {PUBLIC_IP}")
        print(f"[REBIND] Private IP: {PRIVATE_IP}")
        print(f"[REBIND] Test hostname: {REBIND_HOSTNAME}")
        print(f"[REBIND] State file: {self.state_file}")

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((DNS_HOST, DNS_PORT))
        sock.settimeout(1.0)  # Allow clean shutdown

        print("[REBIND] Server ready")

        try:
            while True:
                try:
                    data, addr = sock.recvfrom(512)
                    thread = threading.Thread(
                        target=self.handle_query,
                        args=(data, addr, sock),
                        daemon=True
                    )
                    thread.start()
                except socket.timeout:
                    continue
                except Exception as e:
                    print(f"[REBIND] Error: {e}")
        except KeyboardInterrupt:
            print("\n[REBIND] Shutting down")
        finally:
            sock.close()

def main():
    server = DNSRebindServer()

    # Check for reset argument
    if len(sys.argv) > 1 and sys.argv[1] == 'reset':
        server.reset()
        print("[REBIND] Reset complete")
        sys.exit(0)

    server.run()

if __name__ == '__main__':
    main()
