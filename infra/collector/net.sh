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

# /proc/sys/kernel/hostname is UTS-namespaced: it answers for the READER, not for
# the /proc that was mounted, so from in here it returns the container's random id
# (06ba2e55dacb) and looks plausible. PID 1's root is the host filesystem, so its
# /etc/hostname is the real one.
HOST_NAME=$(cat "$PROC/1/root/etc/hostname" 2>/dev/null | head -n1 | tr -d ' \t\r') || true
[ -n "${HOST_NAME:-}" ] || HOST_NAME=unknown

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
#
# Each address is attributed to an interface through the routing table, because
# the label cannot be worked out from the address alone. A host running Docker
# holds 172.17.0.1, 172.18.0.1 and one per user-defined network — all RFC1918,
# all indistinguishable from a real LAN by range, and none of them somewhere you
# can reach this box from. Listing them as "LAN" is worse than not listing them:
# it buries the one address that works among five that never will.
#
# Matching is longest-prefix, the same rule the kernel uses. Masks are contiguous,
# so (2^32 - mask) is the size of the host part and integer division by it
# compares exactly the network bits — busybox awk has no bitwise operators.
ADDR_TSV=$(awk "$HEX2DEC"'
    function le32(h) {
        # /proc stores addresses little-endian: first octet in the LAST byte.
        return h2d(substr(h,7,2)) * 16777216 + h2d(substr(h,5,2)) * 65536 \
             + h2d(substr(h,3,2)) * 256 + h2d(substr(h,1,2))
    }
    function ip2int(ip,   o) {
        split(ip, o, ".")
        return o[1] * 16777216 + o[2] * 65536 + o[3] * 256 + o[4]
    }

    # Pass 1: the routing table.
    FNR == NR {
        if (FNR == 1) next
        if ($8 == "00000000") next          # default route matches everything
        n++; rnet[n] = le32($2); rshift[n] = 4294967296 - le32($8); riface[n] = $1
        next
    }

    # Pass 2: local addresses out of fib_trie.
    /\|--/ { ip = $2; next }
    /host LOCAL/ {
        if (ip == "" || ip ~ /^127\./) next
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
        split(ip, o, ".")
        if (o[1] == 169 && o[2] == 254) next

        # Longest prefix wins: the smallest host part.
        a = ip2int(ip); iface = ""; best = 4294967297
        for (i = 1; i <= n; i++) {
            if (rshift[i] < best && int(a / rshift[i]) == int(rnet[i] / rshift[i])) {
                best = rshift[i]; iface = riface[i]
            }
        }

        # Container plumbing: the host end of a bridge. Real, and useless here.
        if (iface ~ /^(docker|br-|veth|virbr|cni|flannel|kube)/) next

        kind = "public"
        if (o[1] == 10 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168))
            kind = "lan"
        # 100.64.0.0/10 is the CGNAT range Tailscale allocates from.
        if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) kind = "tailscale"
        if (iface ~ /^(tailscale|ts)/) kind = "tailscale"
        print kind "\t" ip
    }
' "$HOSTNET/route" "$HOSTNET/fib_trie" 2>/dev/null | sort -u || true)

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
