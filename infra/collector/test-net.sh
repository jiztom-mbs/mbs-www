#!/bin/sh
# Check net.sh against fixture /proc trees.
#
# The /proc formats it reads are stable but fiddly — fib_trie splits an address
# across two lines, and both the gateway and listening ports are little-endian
# hex. A misparse is silent: it puts a plausible wrong address on the page, which
# is worse than showing none, and the only other way to find out is to be on the
# host when SSH is already broken.
#
# Run: sh infra/collector/test-net.sh
set -eu

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
PASS=0
FAIL=0

check() {
    _what=$1; _got=$2; _want=$3
    if [ "$_got" = "$_want" ]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$_what"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$_what" "$_got" "$_want"
    fi
}

# --- A host that looks like mbs-ub: a LAN lease, Tailscale, sshd up ----------
mk_proc() {
    _root=$1
    mkdir -p "$_root/1/net" "$_root/1/root/etc" "$_root/sys/kernel"
    # The real host name lives on PID 1's root filesystem. The sysctl below is
    # UTS-namespaced and answers for the reader, so from inside a container it
    # returns the container id — which looks entirely plausible and is wrong.
    printf 'mbs-ub-01\n' > "$_root/1/root/etc/hostname"
    printf 'some-container-id\n' > "$_root/sys/kernel/hostname"

    # fib_trie: the address is on the |-- line, its scope on the next, and the
    # whole table repeats under Local:.
    cat > "$_root/1/net/fib_trie" <<'FIB'
Main:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 10.10.1.0/24 2 0 2
        |-- 10.10.1.0
           /32 link BROADCAST
        |-- 10.10.1.223
           /32 host LOCAL
        |-- 10.10.1.255
           /32 link BROADCAST
     +-- 100.96.0.2/32 2 0 2
        |-- 100.96.0.2
           /32 host LOCAL
     +-- 172.17.0.0/16 2 0 2
        |-- 172.17.0.1
           /32 host LOCAL
     +-- 172.18.0.0/16 2 0 2
        |-- 172.18.0.1
           /32 host LOCAL
     +-- 127.0.0.0/8 2 0 2
        |-- 127.0.0.1
           /32 host LOCAL
     +-- 169.254.0.0/16 2 0 2
        |-- 169.254.7.7
           /32 host LOCAL
Local:
     +-- 10.10.1.0/24 2 0 2
        |-- 10.10.1.223
           /32 host LOCAL
FIB

    # route: default via 10.10.1.1 on enp1s0. The gateway is a little-endian
    # 32-bit word, so 10.10.1.1 (0A 0A 01 01) is written 01010A0A — first octet
    # in the LAST byte. Getting this backwards is the whole reason it is tested.
    cat > "$_root/1/net/route" <<'ROUTE'
Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
enp1s0	00000000	01010A0A	0003	0	0	100	00000000	0	0	0
enp1s0	000A0A0A	00000000	0001	0	0	100	00FFFFFF	0	0	0
docker0	000011AC	00000000	0001	0	0	0	0000FFFF	0	0	0
br-a1b2c3	000012AC	00000000	0001	0	0	0	0000FFFF	0	0	0
tailscale0	02006064	00000000	0001	0	0	0	FFFFFFFF	0	0	0
ROUTE
}

# sshd listening on 22 (0x0016), state 0A.
listening_tcp() {
    cat <<'TCP'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1
TCP
}

# --- healthy host -----------------------------------------------------------
P="$DIR/healthy"
mk_proc "$P"
listening_tcp > "$P/1/net/tcp"
: > "$P/1/net/tcp6"

OUT=$(PROC="$P" sh "$(dirname "$0")/net.sh")

# Not the container id from the UTS-namespaced sysctl, which is what this
# returned on the real host and looked entirely believable.
check "host hostname, not container" "$(echo "$OUT" | jq -r .hostname)"               "mbs-ub-01"
check "gateway (hex decoded)" "$(echo "$OUT" | jq -r .gateway)"                       "10.10.1.1"
check "ssh listening"         "$(echo "$OUT" | jq -r .ssh.listening)"                 "true"
check "ssh port"              "$(echo "$OUT" | jq -r .ssh.port)"                      "22"
check "two addresses only"    "$(echo "$OUT" | jq -r '.addresses | length')"          "2"
# The bug this caught on the real host: five Docker bridge gateways, every one
# RFC1918 and indistinguishable from a real LAN by range, burying the single
# address anyone can actually reach. Attributed by interface, not by range.
check "docker bridges dropped" "$(echo "$OUT" | jq -r '[.addresses[]|select(.address|startswith("172."))]|length')" "0"
check "LAN address labelled"  "$(echo "$OUT" | jq -r '.addresses[]|select(.kind=="lan").address')"       "10.10.1.223"
check "Tailscale labelled"    "$(echo "$OUT" | jq -r '.addresses[]|select(.kind=="tailscale").address')" "100.96.0.2"
# The three that must never appear: loopback is noise, link-local means DHCP
# failed and is not somewhere you can connect, and broadcast is not an address.
check "no loopback"           "$(echo "$OUT" | jq -r '[.addresses[]|select(.address|startswith("127."))]|length')"     "0"
check "no link-local"         "$(echo "$OUT" | jq -r '[.addresses[]|select(.address|startswith("169.254."))]|length')" "0"
check "no broadcast"          "$(echo "$OUT" | jq -r '[.addresses[]|select(.address=="10.10.1.255")]|length')"         "0"
# Deduped across the Main: and Local: tables, which both list 10.10.1.223.
check "deduped"               "$(echo "$OUT" | jq -r '[.addresses[]|select(.address=="10.10.1.223")]|length')"         "1"

# --- sshd down: the page must say so, not omit it ---------------------------
P2="$DIR/nossh"
mk_proc "$P2"
printf '  sl  local_address rem_address   st\n' > "$P2/1/net/tcp"
: > "$P2/1/net/tcp6"
OUT2=$(PROC="$P2" sh "$(dirname "$0")/net.sh")
check "ssh down reported"     "$(echo "$OUT2" | jq -r .ssh.listening)"                "false"
check "addresses still found" "$(echo "$OUT2" | jq -r '.addresses | length')"         "2"

# --- a non-standard ssh port ------------------------------------------------
OUT3=$(PROC="$P" SSH_PORT=2222 sh "$(dirname "$0")/net.sh")
check "wrong port not matched" "$(echo "$OUT3" | jq -r .ssh.listening)"               "false"
check "port reported back"     "$(echo "$OUT3" | jq -r .ssh.port)"                    "2222"

# --- an unreadable /proc must degrade, never abort the collector ------------
P4="$DIR/empty"
mkdir -p "$P4"
OUT4=$(PROC="$P4" sh "$(dirname "$0")/net.sh")
check "missing proc: valid json" "$(echo "$OUT4" | jq -r 'type')"                     "object"
check "missing proc: no addrs"   "$(echo "$OUT4" | jq -r '.addresses | length')"      "0"
check "missing proc: gateway"    "$(echo "$OUT4" | jq -r '.gateway')"                 "null"
check "missing proc: hostname"   "$(echo "$OUT4" | jq -r '.hostname')"                "unknown"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
