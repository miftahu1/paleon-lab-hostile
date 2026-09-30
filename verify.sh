#!/usr/bin/env bash
set -euo pipefail
# PALEON SITE 7 — RUNTIME VERIFICATION (Dedicated Subdomain Architecture)
# Usage (run ON the instance): sudo ./verify.sh <site7-eip> [apex-hostname]
# Inspects hostile stimuli WITHOUT following them; verifies dedicated subdomains,
# malformed HTTP/TLS, slow TLS, and queries the authoritative DNS rebinder directly.

PASS=0
FAIL=0
CURL_TIMEOUT=15
REBIND_NAME="rebind-test.paleon-lab-hostile.com"

check_pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
check_fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
note()       { echo "[NOTE] $1"; }
section()    { echo; echo "== $1 =="; }

usage() {
    echo "Usage: sudo ./verify.sh <site7-eip> [apex-hostname]" >&2
    echo "  <site7-eip>       Elastic IP of the Site 7 instance (queried on :53)" >&2
    echo "  [apex-hostname]   Primary domain (default: paleon-lab-hostile.com)" >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
EIP="$1"
APEX="${2:-paleon-lab-hostile.com}"
APP="http://127.0.0.1:5000"

if ! printf '%s' "$EIP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "[FATAL] '$EIP' is not an IPv4 address" >&2
    usage
fi

echo "=== PALEON SITE 7 RUNTIME VERIFICATION ==="
echo "EIP=$EIP  APEX=$APEX  APP=$APP"

# --- helpers ---------------------------------------------------------------
curl_head() { curl -s -D - -o /dev/null --max-time "$CURL_TIMEOUT" "$@" 2>/dev/null | tr -d '\r'; }
curl_body() { curl -s --max-time "$CURL_TIMEOUT" "$@" 2>/dev/null; }
http_code() { printf '%s\n' "$1" | awk 'NR==1{print $2}'; }
http_hdr()  { printf '%s\n' "$2" | awk -v k="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'tolower($1)==k":"{print $2; exit}'; }
field()     { printf '%s' "$2" | cut -d'|' -f"$1"; }
health_payload_ok() {
    printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("status") == "ok" and d.get("service") == "paleon-site7" else 1)' 2>/dev/null
}

# Direct DNS query using only python3 stdlib
dnsq() {
    python3 - "$1" "$2" "$3" "$4" 2>/dev/null <<'PY'
import socket, struct, sys
server, name, qtype_s, proto = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
qtype = {"A": 1, "TXT": 16, "AAAA": 28}.get(qtype_s.upper(), 1)

def encode_name(n):
    out = b""
    for part in n.rstrip(".").split("."):
        out += bytes([len(part)]) + part.encode("ascii")
    return out + b"\x00"

def skip_name(data, off):
    while off < len(data):
        l = data[off]
        if l == 0:
            return off + 1
        if l & 0xC0 == 0xC0:
            return off + 2
        off += 1 + l
    return off

q = struct.pack("!HHHHHH", 0x1234, 0x0000, 1, 0, 0, 0)
q += encode_name(name) + struct.pack("!HH", qtype, 1)
try:
    if proto == "tcp":
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect((server, 53))
        s.sendall(struct.pack("!H", len(q)) + q)
        ln = s.recv(2)
        if len(ln) < 2:
            print(""); sys.exit(0)
        n = struct.unpack("!H", ln)[0]
        data = b""
        while len(data) < n:
            c = s.recv(n - len(data))
            if not c:
                break
            data += c
        s.close()
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3.0)
        s.sendto(q, (server, 53))
        data, _ = s.recvfrom(4096)
        s.close()
except Exception:
    print(""); sys.exit(0)

if len(data) < 12:
    print(""); sys.exit(0)
_tid, flags, qd, an, _ns, _ar = struct.unpack("!HHHHHH", data[:12])
rcode = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}.get(flags & 0xF, str(flags & 0xF))
aa = (flags >> 10) & 1
ra = (flags >> 7) & 1
off = 12
for _ in range(qd):
    off = skip_name(data, off) + 4
ttl, answer = "", ""
for _ in range(an):
    off = skip_name(data, off)
    if off + 10 > len(data):
        break
    rtype, _rclass, rttl, rdlen = struct.unpack("!HHIH", data[off:off + 10])
    off += 10
    rdata = data[off:off + rdlen]
    off += rdlen
    if answer == "" and rtype == 1 and rdlen == 4:
        answer = ".".join(str(b) for b in rdata)
        ttl = str(rttl)
print("%s|%d|%d|%s|%s" % (rcode, aa, ra, ttl, answer))
PY
}

# --- 0. tool preflight -----------------------------------------------------
section "0. Tool preflight"
for tool in curl openssl ss systemctl python3 gzip timeout; do
    if command -v "$tool" >/dev/null 2>&1; then
        check_pass "tool present: $tool"
    else
        check_fail "required tool missing: $tool"
    fi
done

# --- 1. systemd services ---------------------------------------------------
section "1. Systemd services active"
for svc in paleon-site7 site7-malformed-server site7-rebind-dns nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        check_pass "service active: $svc"
    else
        check_fail "service not active: $svc"
    fi
done

# --- 2. listeners ----------------------------------------------------------
section "2. Listening sockets"
check_tcp() {
    if ss -tlnp 2>/dev/null | grep -qE "$1"; then check_pass "tcp listener: $2"; else check_fail "tcp listener missing: $2"; fi
}
check_tcp '127\.0\.0\.1:5000\b' "127.0.0.1:5000 (Flask)"
check_tcp '127\.0\.0\.1:8443\b' "127.0.0.1:8443 (internal TLS term)"
check_tcp '127\.0\.0\.1:9997\b' "127.0.0.1:9997 (slow TLS)"
check_tcp '127\.0\.0\.1:9998\b' "127.0.0.1:9998 (malformed TLS)"
check_tcp '127\.0\.0\.1:9999\b' "127.0.0.1:9999 (malformed HTTP)"
check_tcp ':80\b'  "0.0.0.0:80 (nginx http)"
check_tcp ':443\b' "0.0.0.0:443 (nginx stream)"
check_tcp ':53\b'  "0.0.0.0:53 (DNS tcp)"
if ss -ulnp 2>/dev/null | grep -qE ':53\b'; then check_pass "udp listener: 0.0.0.0:53 (DNS udp)"; else check_fail "udp listener missing: 0.0.0.0:53"; fi

# --- 3. health + homepage (Flask direct) -----------------------------------
section "3. Health & homepage (Flask 127.0.0.1:5000)"
hb="$(curl_body "$APP/health")" || hb=""
if health_payload_ok "$hb"; then
    check_pass "/health -> {status: ok, service: paleon-site7}"
else
    check_fail "/health payload wrong or unreachable: $hb"
fi
home="$(curl_body "$APP/")" || home=""
if printf '%s' "$home" | grep -q "Paleon Site 7"; then
    check_pass "homepage contains 'Paleon Site 7'"
else
    check_fail "homepage missing marker / unreachable"
fi

# --- 4. SSRF redirect stimuli (inspect Location on dedicated subdomains) ---
section "4. SSRF Location headers on dedicated subdomains (SSRF-001..004)"
# subdomain|query|expected-Location-substring
SSRF=(
    "fargate||http://169.254.170.2/v2/credentials/TEST_ONLY"
    "imds||http://169.254.169.254/latest/meta-data/"
    "rfc1918||http://10.0.0.1/"
    "rfc1918|?target=172|http://172.16.0.1/"
    "rfc1918|?target=192|http://192.168.0.1/"
    "loopback||http://127.0.0.1/"
    "ipv6||http://[fd00::1]/"
)
for entry in "${SSRF[@]}"; do
    sub="${entry%%|*}"
    rest="${entry#*|}"
    query="${rest%%|*}"
    want="${rest#*|}"
    h="$(curl_head -H "Host: $sub.$APEX" "$APP/$query")" || h=""
    code="$(http_code "$h")"
    loc="$(http_hdr Location "$h")"
    if [ "$code" = "302" ] && [ "$loc" = "$want" ]; then
        check_pass "SSRF $sub.$APEX$query -> 302 $want"
    else
        check_fail "SSRF $sub.$APEX$query: code='$code' location='$loc' (want 302 '$want')"
    fi
done

# --- 5. scope escape on dedicated subdomain (SAFE-001) ---------------------
section "5. Scope escape (SAFE-001) on offscope-redirect subdomain"
h="$(curl_head -H "Host: offscope-redirect.$APEX" "$APP/")" || h=""
code="$(http_code "$h")"; loc="$(http_hdr Location "$h")"
if [ "$code" = "302" ] && printf '%s' "$loc" | grep -q '^https://' && ! printf '%s' "$loc" | grep -q "\.$APEX"; then
    check_pass "offscope-redirect -> 302 $loc (separate offscope domain)"
else
    check_fail "offscope-redirect: code='$code' location='$loc' (want 302 to separate offscope domain)"
fi

# --- 6. redirect loop + self-loop (SAFE-002) -------------------------------
section "6. Redirect cycle (SAFE-002) on dedicated subdomains"
h_entry="$(curl_head -H "Host: redirect-loop.$APEX" "$APP/")" || h_entry=""
loc_entry="$(http_hdr Location "$h_entry")"
if [ "$(http_code "$h_entry")" = "302" ] && [ "$loc_entry" = "/b" ]; then
    check_pass "redirect-loop / -> 302 /b"
else
    check_fail "redirect-loop /: code='$(http_code "$h_entry")' loc='$loc_entry'"
fi

h_b="$(curl_head -H "Host: redirect-loop.$APEX" "$APP/b")" || h_b=""
if [ "$(http_code "$h_b")" = "302" ] && [ "$(http_hdr Location "$h_b")" = "/c" ]; then
    check_pass "redirect-loop /b -> 302 /c"
else
    check_fail "redirect-loop /b: loc='$(http_hdr Location "$h_b")'"
fi

h_c="$(curl_head -H "Host: redirect-loop.$APEX" "$APP/c")" || h_c=""
if [ "$(http_code "$h_c")" = "302" ] && [ "$(http_hdr Location "$h_c")" = "/a" ]; then
    check_pass "redirect-loop /c -> 302 /a"
else
    check_fail "redirect-loop /c: loc='$(http_hdr Location "$h_c")'"
fi

h_self="$(curl_head -H "Host: self-loop.$APEX" "$APP/")" || h_self=""
if [ "$(http_code "$h_self")" = "302" ] && printf '%s' "$(http_hdr Location "$h_self")" | grep -q "self-loop"; then
    check_pass "self-loop -> 302 to self"
else
    check_fail "self-loop failed"
fi

# --- 7. resource exhaustion (SAFE-003) -------------------------------------
section "7. Resource exhaustion (SAFE-003) on dedicated subdomains"
h="$(curl_head -H "Host: large-body.$APEX" "$APP/?size_mb=2")" || h=""
code="$(http_code "$h")"; cl="$(http_hdr Content-Length "$h")"; ct="$(http_hdr Content-Type "$h")"
if [ "$code" = "200" ] && [ "$cl" = "2097152" ] && printf '%s' "$ct" | grep -q "application/octet-stream"; then
    check_pass "large-body -> 200, Content-Length 2097152, octet-stream"
else
    check_fail "large-body: code='$code' len='$cl' type='$ct'"
fi

sb="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 -H "Host: slow-body.$APEX" "$APP/?delay_ms=1000")" || sb=""
sbcode="$(printf '%s' "$sb" | awk '{print $1}')"; sbtime="$(printf '%s' "$sb" | awk '{print $2}')"
if [ "$sbcode" = "200" ] && awk -v t="${sbtime:-0}" 'BEGIN{exit !(t+0>=0.8)}'; then
    check_pass "slow-body -> 200 after ${sbtime}s"
else
    check_fail "slow-body: code='$sbcode' time='$sbtime' (want 200, >=0.8s)"
fi

h="$(curl_head -H "Host: gzip-body.$APEX" "$APP/")" || h=""
ce="$(http_hdr Content-Encoding "$h")"; xd="$(http_hdr X-Decompressed-Size "$h")"
if printf '%s' "$ce" | grep -q "gzip" && [ "$xd" = "10485760" ]; then
    check_pass "gzip-body headers: Content-Encoding gzip, X-Decompressed-Size 10485760"
else
    check_fail "gzip-body headers: encoding='$ce' x-decompressed='$xd'"
fi
dc="$(curl_body -H "Host: gzip-body.$APEX" "$APP/" | gzip -dc | wc -c)" || dc=""
if [ "$dc" = "10485760" ]; then
    check_pass "gzip-body decompresses to exactly 10485760 bytes"
else
    check_fail "gzip-body decompressed size = '$dc' (want 10485760)"
fi

# --- 8. new stimuli: ftp-redirect (SAFE-008) and slow-drip (SAFE-009) ------
section "8. New hostile stimuli (ftp-redirect, slow-drip)"
h_ftp="$(curl_head -H "Host: ftp-redirect.$APEX" "$APP/")" || h_ftp=""
loc_ftp="$(http_hdr Location "$h_ftp")"
if [ "$(http_code "$h_ftp")" = "302" ] && printf '%s' "$loc_ftp" | grep -q '^ftp://rebind-test\.'; then
    check_pass "ftp-redirect -> 302 $loc_ftp"
else
    check_fail "ftp-redirect: code='$(http_code "$h_ftp")' loc='$loc_ftp'"
fi

sd="$(curl -s -N --max-time 2 -H "Host: slow-drip.$APEX" "$APP/" 2>/dev/null || printf '')"
if [ "$sd" = "X" ]; then
    check_pass "slow-drip streams initial 1 byte cleanly"
else
    check_fail "slow-drip initial byte failed: '$sd'"
fi

# --- 9. malformed HTTP over real TLS via SNI (SAFE-004) --------------------
section "9. Malformed HTTP via SNI (SAFE-004) — raw bytes over TLS"
tls_send() {
    printf 'GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$2" "$1" \
        | timeout 15 openssl s_client -connect 127.0.0.1:443 -servername "$1" -quiet 2>/dev/null
}
CHUNK_FILE="$(mktemp)"
if tls_send "malformed-http.$APEX" "/chunked" > "$CHUNK_FILE"; then :; fi
if grep -qa 'Transfer-Encoding: chunked' "$CHUNK_FILE" && grep -qa '^GARBAGE' "$CHUNK_FILE"; then
    check_pass "malformed chunked: 'Transfer-Encoding: chunked' + invalid 'GARBAGE' chunk size"
else
    check_fail "malformed chunked: expected markers not found in raw response"
fi
BANNER_FILE="$(mktemp)"
if tls_send "malformed-http.$APEX" "/banner" > "$BANNER_FILE"; then :; fi
if grep -qa 'X-Control-Header' "$BANNER_FILE" && LC_ALL=C grep -qaP '\x00\x01\x02\x03' "$BANNER_FILE"; then
    check_pass "malformed banner: X-Control-Header carries raw control bytes 00 01 02 03"
else
    check_fail "malformed banner: control-byte header not found in raw response"
fi
rm -f "$CHUNK_FILE" "$BANNER_FILE"

# --- 10. malformed TLS (SAFE-004-TLS) & slow TLS (SAFE-010-TLS) ------------
section "10. Malformed TLS & Slow TLS via SNI"
tls_ec=0
tls_out="$(printf '' | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "malformed-tls.$APEX" 2>&1)" || tls_ec=$?
if printf '%s' "$tls_out" | grep -q 'BEGIN CERTIFICATE'; then
    check_fail "malformed-tls presented a valid certificate (handshake unexpectedly succeeded)"
elif [ "$tls_ec" -ne 0 ] || printf '%s' "$tls_out" | grep -qiE 'handshake failure|alert|wrong version number|unknown protocol|ssl3_|tls_|routines'; then
    check_pass "malformed-tls: TLS handshake fails on garbled ServerHello (exit=$tls_ec)"
else
    check_fail "malformed-tls: no certificate but handshake did not clearly fail"
fi

start_slow=$(date +%s)
slow_ec=0
slow_out="$(printf '' | timeout 15 openssl s_client -connect 127.0.0.1:443 -servername "slow-tls.$APEX" 2>&1)" || slow_ec=$?
end_slow=$(date +%s)
slow_dur=$((end_slow - start_slow))
if [ "$slow_dur" -ge 8 ]; then
    check_pass "slow-tls handshake intentionally delayed (duration: ${slow_dur}s)"
else
    check_fail "slow-tls completed too quickly (${slow_dur}s)"
fi

# --- 11. Nginx edge: default SNI reaches Flask; :80 redirects --------------
section "11. Nginx SNI edge (:443 default -> 8443 -> Flask, :80 -> 301)"
edge="$(curl -k -sS --max-time "$CURL_TIMEOUT" --resolve "$APEX:443:127.0.0.1" \
        -w '|%{http_code}' "https://$APEX/health")" || edge=""
edge_code="${edge##*|}"
edge_body="${edge%|*}"
if [ "$edge_code" = "200" ] && health_payload_ok "$edge_body"; then
    check_pass "default SNI ($APEX) terminates TLS on :443 and reaches Flask /health"
else
    check_fail "default SNI path did not reach Flask /health over :443"
fi
h80="$(curl_head "http://127.0.0.1:80/health")" || h80=""
code80="$(http_code "$h80")"; loc80="$(http_hdr Location "$h80")"
if [ "$code80" = "301" ] && printf '%s' "$loc80" | grep -q '^https://'; then
    check_pass ":80 returns 301 -> $loc80"
else
    check_fail ":80 redirect wrong: code='$code80' location='$loc80'"
fi

# --- 12. read-only observer (SAFE-005) -------------------------------------
section "12. Read-only observer (SAFE-005) on observer subdomain"
ro_ok=1
for m in GET POST PUT DELETE PATCH OPTIONS; do
    c="$(curl -s -X "$m" -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" -H "Host: observer.$APEX" "$APP/")" || c=""
    if [ "$c" != "200" ]; then ro_ok=0; check_fail "observer $m -> '$c' (want 200)"; fi
done
if [ "$ro_ok" = "1" ]; then check_pass "observer returns 200 for GET/POST/PUT/DELETE/PATCH/OPTIONS"; fi
hc="$(curl -s -I -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" -H "Host: observer.$APEX" "$APP/")" || hc=""
if [ "$hc" = "200" ]; then check_pass "observer HEAD -> 200"; else check_fail "observer HEAD -> '$hc'"; fi
rob="$(curl_body -X POST -H "Host: observer.$APEX" "$APP/")" || rob=""
if printf '%s' "$rob" | grep -q "Request observed and logged"; then
    check_pass "observer body records the observation"
else
    check_fail "observer body missing observation marker: '$rob'"
fi

# --- 13. kill test (SAFE-006) ----------------------------------------------
section "13. Kill test (SAFE-006) on kill-test subdomain"
kt="$(curl -s -N --max-time 3 -H "Host: kill-test.$APEX" "$APP/" 2>/dev/null || printf '')"
if printf '%s' "$kt" | grep -q "Connection held"; then
    check_pass "kill-test streams initial chunk then holds (client can terminate cleanly)"
else
    check_fail "kill-test did not stream expected initial chunk"
fi

# --- 14. observation endpoint (localhost-only) -----------------------------
section "14. Observation store (localhost-only)"
obs="$(curl_body "$APP/internal/site7-observation")" || obs=""
if printf '%s' "$obs" | grep -q '"total_observations"'; then
    check_pass "/internal/site7-observation returns observation JSON locally"
else
    check_fail "/internal/site7-observation not returning JSON locally"
fi

# --- 15. DNS rebinding, authoritative + direct (SAFE-007) ------------------
section "15. DNS rebinding (SAFE-007) — direct authoritative queries"
DNS_SERVER="$EIP"
p1="$(dnsq "$DNS_SERVER" "$REBIND_NAME" A udp)" || p1=""
if [ -z "$p1" ]; then
    note "No response from $EIP:53 (EIP may not hairpin from the instance); using 127.0.0.1"
    DNS_SERVER="127.0.0.1"
    p1="$(dnsq "$DNS_SERVER" "$REBIND_NAME" A udp)" || p1=""
fi
p2="$(dnsq "$DNS_SERVER" "$REBIND_NAME" A udp)" || p2=""
ptcp="$(dnsq "$DNS_SERVER" "$REBIND_NAME" A tcp)" || ptcp=""
ptxt="$(dnsq "$DNS_SERVER" "$REBIND_NAME" TXT udp)" || ptxt=""
pref="$(dnsq "$DNS_SERVER" "not-authoritative.example" A udp)" || pref=""

rc1="$(field 1 "$p1")"; aa1="$(field 2 "$p1")"; ra1="$(field 3 "$p1")"; ttl1="$(field 4 "$p1")"; ans1="$(field 5 "$p1")"
ans2="$(field 5 "$p2")"
rctcp="$(field 1 "$ptcp")"; aatcp="$(field 2 "$ptcp")"; anstcp="$(field 5 "$ptcp")"
rctxt="$(field 1 "$ptxt")"; anstxt="$(field 5 "$ptxt")"
rcref="$(field 1 "$pref")"

if [ -z "$p1" ]; then
    check_fail "DNS server did not respond on $DNS_SERVER:53"
else
    if [ "$rc1" = "NOERROR" ] && [ "$aa1" = "1" ] && [ "$ra1" = "0" ] && [ "$ttl1" = "0" ]; then
        check_pass "query #1 authoritative: NOERROR, AA=1, RA=0, TTL=0 (answer=$ans1)"
    else
        check_fail "query #1 flags wrong: rcode=$rc1 AA=$aa1 RA=$ra1 TTL=$ttl1"
    fi
    if [ "$ans2" = "192.168.1.1" ]; then
        check_pass "query #2 rebinds to private 192.168.1.1"
    else
        check_fail "query #2 answer='$ans2' (want 192.168.1.1)"
    fi
    if [ "$ans1" = "$EIP" ]; then
        check_pass "clean transition observed: #1=$EIP (public) -> #2=192.168.1.1 (private)"
    elif [ "$ans1" = "192.168.1.1" ]; then
        note "client state was already advanced (run ./reset.sh for the full public->private demo); private-after-rebind invariant holds"
    else
        check_fail "query #1 answer='$ans1' (expected public EIP $EIP or already-private 192.168.1.1)"
    fi
    if [ "$rctcp" = "NOERROR" ] && [ "$aatcp" = "1" ] && [ -n "$anstcp" ]; then
        check_pass "TCP query answered authoritatively (answer=$anstcp)"
    else
        check_fail "TCP query failed: rcode=$rctcp AA=$aatcp answer='$anstcp'"
    fi
    if [ "$rctxt" = "NOERROR" ] && [ -z "$anstxt" ]; then
        check_pass "TXT on test name -> NOERROR NoData (no A leaked)"
    else
        check_fail "TXT query unexpected: rcode=$rctxt answer='$anstxt'"
    fi
    if [ "$rcref" = "REFUSED" ]; then
        check_pass "out-of-zone name -> REFUSED (authoritative-only, no recursion)"
    else
        check_fail "out-of-zone name rcode='$rcref' (want REFUSED)"
    fi
fi

# --- summary ---------------------------------------------------------------
echo
echo "=== VERIFICATION SUMMARY ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL VERIFICATIONS PASSED"
    exit 0
fi
echo "VERIFICATION FAILED"
exit 1
