#!/bin/sh
# Write the two status files the pages read.
#
#   /out/public/status.json    service name + up/down only        (public)
#   /out/detail/detail.json    host metrics, images, restarts     (Access-gated)
#
# The split is the security boundary, not a convenience. The public file must
# never carry a version, an image tag, a port or a hostname — on a page anyone can
# open, those are reconnaissance. Everything richer goes in the detail file, which
# nginx serves only from under /detail/, where one Cloudflare Access policy covers
# both the page and the data.
#
# This script talks to Docker over the mounted socket and reads host metrics from
# /host/proc. It has `network_mode: none`, so nothing can reach it — the only way
# its output escapes is the file nginx serves.
set -eu

OUT=/out
PROC=/host/proc

# --- Which containers matter, and what to call them in public ----------------
#
# An explicit list, not "every container". A new container appearing on this box
# should not silently publish its existence, and the friendly name is what a
# reader can act on — "Database" means something, "supabase-db" is our plumbing.
#
#   <container name>|<public label>
SERVICES='supabase-db|Database
supabase-kong|API
supabase-auth|Auth
supabase-storage|Storage
supabase-rest|REST
realtime-dev.supabase-realtime|Realtime
gitea-gitea-1|Git
edge-web-nginx-1|Web'

# --- Host metrics ------------------------------------------------------------

cpu_pct() {
    # Two samples of /proc/stat one second apart. A single read gives cumulative
    # totals since boot, which on a box up for weeks is a flat average and tells
    # you nothing about now.
    set -- $(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' "$PROC/stat")
    busy1=$1; idle1=$2
    sleep 1
    set -- $(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' "$PROC/stat")
    busy2=$1; idle2=$2
    db=$((busy2 - busy1)); di=$((idle2 - idle1)); tot=$((db + di))
    [ "$tot" -le 0 ] && { echo 0; return; }
    echo $((db * 100 / tot))
}

mem_line() {
    awk '
      /^MemTotal:/     {t=$2}
      /^MemAvailable:/ {a=$2}
      END {
        if (t > 0)
          # MemAvailable, not MemFree: free excludes cache the kernel will hand
          # back on demand, so it reports pressure that is not real.
          printf "%.1f %.1f %d", (t-a)/1048576, t/1048576, int((t-a)*100/t)
        else print "0 0 0"
      }' "$PROC/meminfo"
}

disk_line() {
    # df on the bind-mounted output directory reports the HOST filesystem holding
    # it. That avoids mounting the host root just to read a number.
    df -k "$OUT" | awk 'NR==2 {printf "%d %d %d", $3/1048576, $2/1048576, int($3*100/$2)}'
}

CPU=$(cpu_pct)
set -- $(mem_line);  MEM_USED=$1; MEM_TOTAL=$2; MEM_PCT=$3
set -- $(disk_line); DISK_USED=$1; DISK_TOTAL=$2; DISK_PCT=$3
LOAD1=$(awk '{print $1}' "$PROC/loadavg")
UP_S=$(awk '{print int($1)}' "$PROC/uptime")
if [ "$UP_S" -ge 86400 ]; then UPTIME="$((UP_S / 86400))d"
elif [ "$UP_S" -ge 3600 ]; then UPTIME="$((UP_S / 3600))h"
else UPTIME="$((UP_S / 60))m"; fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Network -----------------------------------------------------------------
#
# Split into net.sh so the /proc parsing can be checked against fixtures without
# being on the host — see test-net.sh. A misparse here is silent and would put a
# plausible wrong address on the page, which is worse than showing none.
#
# DETAIL ONLY, and the assignment below is the only place it is used: an address,
# a hostname and a live SSH port are a starting point for someone, and anyone can
# open the public page. See the note at the top of this script.
NETWORK_JSON=$(PROC="$PROC" SSH_PORT="${SSH_PORT:-22}" sh /usr/local/bin/net.sh 2>/dev/null \
  || echo '{"hostname":"unknown","addresses":[],"gateway":null,"ssh":{"port":22,"listening":false}}')

# --- Deployments -------------------------------------------------------------
#
# Two independent facts, and they can disagree — which is exactly why both are
# reported rather than one being inferred from the other:
#
#   live      what the `current` symlink points at right now. This is the truth
#             about what visitors are being served.
#   last      the most recent deploy attempt and how it ended.
#
# A rolled-back deploy is the case that matters: `last` says failed while `live`
# still holds the previous good release. Showing only the log would imply the site
# is down; showing only the symlink would hide that a deploy broke.
SITES_DIR=${SITES_DIR:-/www}
LOG=${DEPLOY_LOG:-/deploy/log/deploys.jsonl}

: > /tmp/deploys.jsonl
for site in $(ls -1 "$SITES_DIR" 2>/dev/null); do
    live=$(readlink "$SITES_DIR/$site/current" 2>/dev/null | sed 's|^releases/||')
    [ -z "$live" ] && live="none"
    # Last recorded attempt for this site, whatever its outcome.
    last=$(grep "\"site\":\"$site\"" "$LOG" 2>/dev/null | tail -1)
    if [ -n "$last" ]; then
        printf '%s\n' "$last" | jq -c --arg live "$live" '. + {live: $live}' >> /tmp/deploys.jsonl 2>/dev/null || true
    else
        jq -cn --arg site "$site" --arg live "$live" \
          '{site: $site, live: $live, ref: $live, status: "unknown", at: null, detail: "no deploy recorded"}' \
          >> /tmp/deploys.jsonl
    fi
done

# --- Containers --------------------------------------------------------------

PUBLIC_ITEMS=''
DETAIL_ITEMS=''

echo "$SERVICES" | while IFS='|' read -r cname label; do
    [ -z "$cname" ] && continue
    # `docker inspect` on a container that does not exist exits non-zero; treat
    # that as down rather than letting `set -e` kill the whole run.
    if info=$(docker inspect "$cname" \
        --format '{{.State.Running}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.Config.Image}}' 2>/dev/null); then
        running=${info%%|*};  rest=${info#*|}
        started=${rest%%|*};  rest=${rest#*|}
        restarts=${rest%%|*}; image=${rest#*|}
    else
        running=false; started=''; restarts=0; image=''
    fi

    [ "$running" = "true" ] && state=up || state=down

    # Uptime from StartedAt, in whole units. Precision beyond this is noise.
    up='—'
    if [ "$state" = up ] && [ -n "$started" ]; then
        s=$(date -u -d "$started" +%s 2>/dev/null || echo 0)
        n=$(date -u +%s)
        [ "$s" -gt 0 ] && d=$((n - s)) && {
            if [ "$d" -ge 86400 ]; then up="$((d / 86400))d"
            elif [ "$d" -ge 3600 ]; then up="$((d / 3600))h"
            else up="$((d / 60))m"; fi
        }
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$state" "$up" "$restarts" "$image"
done > /tmp/svc.tsv

# jq builds both files: hand-rolled JSON breaks the moment a label or an image tag
# contains a quote, and it would break silently as a parse error on the page.
PUBLIC_JSON=$(jq -Rn --arg now "$NOW" '
  [inputs | split("\t") | {name: .[0], state: .[1]}] as $svcs
  | {checked_at: $now, services: $svcs}' < /tmp/svc.tsv)

DETAIL_JSON=$(jq -Rn \
  --arg now "$NOW" --argjson cpu "$CPU" \
  --argjson mu "$MEM_USED" --argjson mt "$MEM_TOTAL" --argjson mp "$MEM_PCT" \
  --argjson du "$DISK_USED" --argjson dt "$DISK_TOTAL" --argjson dp "$DISK_PCT" \
  --arg load "$LOAD1" --arg uptime "$UPTIME" \
  --argjson network "$NETWORK_JSON" '
  [inputs | split("\t")
    | {name: .[0], state: .[1], uptime: .[2], restarts: (.[3] | tonumber), image: .[4]}] as $svcs
  | {checked_at: $now,
     host: {cpu_pct: $cpu, mem_used_gb: $mu, mem_total_gb: $mt, mem_pct: $mp,
            disk_used_gb: $du, disk_total_gb: $dt, disk_pct: $dp,
            load1: ($load | tonumber), uptime: $uptime},
     network: $network,
     containers: $svcs,
     deploys: $deploys}' --argjson deploys "$(jq -sc . < /tmp/deploys.jsonl 2>/dev/null || echo '[]')" < /tmp/svc.tsv)

# --- Publish atomically ------------------------------------------------------
#
# Write then rename. A reader that catches a half-written file gets a parse error
# and the page reports "unknown", which looks like an outage that is not happening.
mkdir -p "$OUT/public" "$OUT/detail"
printf '%s\n' "$PUBLIC_JSON" > "$OUT/public/.status.json.tmp"
mv -f "$OUT/public/.status.json.tmp" "$OUT/public/status.json"
printf '%s\n' "$DETAIL_JSON" > "$OUT/detail/.detail.json.tmp"
mv -f "$OUT/detail/.detail.json.tmp" "$OUT/detail/detail.json"
