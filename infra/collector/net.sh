#!/bin/sh
# Host network facts, as one JSON object on stdout.
#
# Which address this box is actually on — the question you have when SSH stops
# answering. A lease moved this host from 10.10.1.6 to 10.10.1.223 and the only
# symptom was a connection timeout; nothing on any page said so.
#
# Reads /host/proc/1/net, NOT the container's own /proc/net, and that distinction
# is the whole trick. /proc/net is per network namespace and this container
# deliberately has none — but PID 1 is the host's init, so its namespace is the
# host's. `network_mode: none` therefore stays exactly as it was: no new mount,
# no new capability, no network access. This reads a file.
#
# Split out from collect.sh so it can be run against fixture directories, which is
# the only way to check the /proc parsing without being on the host — see
# test-net.sh. The formats here are stable but fiddly, and a silent misparse
# would put a wrong address on the page, which is worse than none.
#
# DETAIL ONLY. The caller must keep this out of the public file: an address, a
# hostname and a live SSH port are a starting point for someone, and anyone can
# open the public page.
set -eu

PROC=${PROC:-/host/proc}
HOSTNET="$PROC/1/net"
SSH_PORT=${SSH_PORT:-22}

HOST_NAME=$(cat "$PROC/sys/kernel/hostname" 2>/dev/null || echo unknown)

# busybox awk has no strtonum, so hex is converted by hand. /proc reports both
# the gateway and listening ports in hex.
HEX2DEC='function h2d(s,   i, c, d, n) {
    n = 0; s = tolower(s)
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        n = n * 16 + d
    }
    return n
}'

# Every local IPv4 address, labelled by what it is good for. fib_trie puts an
# address on a `|--` line and its scope on the next, and prints the whole table
# twice (Main: and Local:) — hence sort -u.
#
# Loopback and link-local are dropped as noise. The rest are labelled rather than
# filtered: the Tailscale address is the one that still works when the LAN lease
# moves, and picking one for the reader would hide exactly that.
ADDR_TSV=$(awk '
    /\|--/ { ip = $2; next }
    /host LOCAL/ {
        if (ip == "" || ip ~ /^127\./) next
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
        split(ip, o, ".")
        if (o[1] == 169 && o[2] == 254) next
        kind = "public"
        if (o[1] == 10 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168))
            kind = "lan"
        # 100.64.0.0/10 is the CGNAT range Tailscale allocates from.
        if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) kind = "tailscale"
        print kind "\t" ip
    }
' "$HOSTNET/fib_trie" 2>/dev/null | sort -u || true)

# Default route: destination and mask both zero, gateway little-endian hex.
GATEWAY=$(awk "$HEX2DEC"'
    NR > 1 && $2 == "00000000" && $8 == "00000000" {
        g = $3
        printf "%d.%d.%d.%d\n", h2d(substr(g,7,2)), h2d(substr(g,5,2)), h2d(substr(g,3,2)), h2d(substr(g,1,2))
        exit
    }
' "$HOSTNET/route" 2>/dev/null || true)

# Is sshd listening? Answered from the socket table, so it needs no network
# access — which this container does not have. State 0A is LISTEN.
SSH_UP=false
for f in "$HOSTNET/tcp" "$HOSTNET/tcp6"; do
    [ -r "$f" ] || continue
    if awk "$HEX2DEC"'
        NR > 1 && $4 == "0A" {
            n = split($2, a, ":")
            if (h2d(a[n]) == PORT) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' PORT="$SSH_PORT" "$f" 2>/dev/null; then
        SSH_UP=true
        break
    fi
done

printf '%s' "$ADDR_TSV" | jq -Rsc \
  --arg hostname "$HOST_NAME" \
  --arg gateway "${GATEWAY:-}" \
  --argjson sshup "$SSH_UP" \
  --argjson sshport "$SSH_PORT" '
  {
    hostname: $hostname,
    addresses: (split("\n") | map(select(length > 0) | split("\t") | {kind: .[0], address: .[1]})),
    gateway: (if $gateway == "" then null else $gateway end),
    ssh: { port: $sshport, listening: $sshup }
  }'
