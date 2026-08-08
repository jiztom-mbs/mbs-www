#!/bin/sh
# deploy.sh <site> <sha>
#
# Fetch, build in a throwaway container, publish as a release, swap the symlink.
#
# The build never runs in THIS container. It runs in a sibling started through the
# Docker socket, which means the -v paths below are resolved by the host daemon,
# not by this filesystem — hence DEPLOY_ROOT_HOST and WWW_ROOT_HOST. Passing the
# in-container path here is the classic sibling-container mistake and produces an
# empty mount rather than an error, so the build silently succeeds and publishes
# nothing.
set -eu

SITE=$1
SHA=$2
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# One JSON object per line. Written at every outcome, including the failures —
# a log of successes only cannot answer "what broke", which is the question
# anyone looking at a deploy log actually has.
record() {
    _status=$1
    _detail=${2:-}
    mkdir -p "${DEPLOY_ROOT:-/deploy}/log"
    printf '{"site":"%s","ref":"%s","status":"%s","at":"%s","started":"%s","detail":"%s"}\n' \
        "$SITE" "$(echo "$SHA" | cut -c1-7)" "$_status" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STARTED" \
        "$(echo "$_detail" | tr -d '"' | cut -c1-160)" \
        >> "${DEPLOY_ROOT:-/deploy}/log/deploys.jsonl"
}

# Any exit that is not an explicit success is a failure. Trapping it means a new
# `exit 1` added later cannot silently stop being recorded.
_done=0
on_exit() {
    _code=$?
    [ "$_done" = 1 ] && exit $_code
    [ "$_code" != 0 ] && record failed "exited $_code"
    exit $_code
}
trap on_exit EXIT

DEPLOY_ROOT=${DEPLOY_ROOT:-/deploy}
WWW_ROOT=${WWW_ROOT:-/www}
DEPLOY_ROOT_HOST=${DEPLOY_ROOT_HOST:?DEPLOY_ROOT_HOST must be the host path}
WWW_ROOT_HOST=${WWW_ROOT_HOST:?WWW_ROOT_HOST must be the host path}
GITEA_INTERNAL=${GITEA_INTERNAL:-http://gitea-gitea-1:3000}
KEEP_RELEASES=${KEEP_RELEASES:-5}

case "$SITE" in
    landing|status)  REPO=MakeBelieveStudio/mbs-www;      SRC=mbs-www ;;
    warehouse)       REPO=MakeBelieveStudio/MBSWareHouse; SRC=warehouse ;;
    *) echo "deploy: unknown site $SITE" >&2; exit 1 ;;
esac

# Credentials only ever appear in the remote URL, and only in memory. Writing them
# into the checkout's .git/config would persist a token on disk for anything that
# later reads that directory.
if [ -n "${GITEA_TOKEN:-}" ]; then
    REMOTE="http://${GITEA_USER:-deploy}:${GITEA_TOKEN}@${GITEA_INTERNAL#http://}/${REPO}.git"
else
    REMOTE="${GITEA_INTERNAL}/${REPO}.git"
fi

WORK="$DEPLOY_ROOT/src/$SRC"
WORK_HOST="$DEPLOY_ROOT_HOST/src/$SRC"

# --- Fetch -------------------------------------------------------------------
mkdir -p "$DEPLOY_ROOT/src"
if [ -d "$WORK/.git" ]; then
    git -C "$WORK" remote set-url origin "$REMOTE"
    git -C "$WORK" fetch --quiet origin
else
    rm -rf "$WORK"
    git clone --quiet "$REMOTE" "$WORK"
fi
git -C "$WORK" reset --hard --quiet "$SHA"
git -C "$WORK" clean -fdq

# --- Build, in a sibling container -------------------------------------------
#
# node:22-alpine, removed afterwards. Nothing is installed on the host, and a
# build cannot leave anything behind on it either.
echo "deploy: building $SITE at $SHA"

if [ "$SITE" = warehouse ]; then
    # These three decide correctness, not convenience:
    #   VITE_SUPABASE_URL   is compiled into the bundle AND drives the generated
    #                       CSP, so a wrong value ships an app that cannot reach
    #                       its own database.
    #   EMIT_HEADERS=1      without it emit-headers.mjs exits early, no CSP file is
    #                       written, and the guard that refuses a local backend
    #                       never runs.
    #   COMMIT_REF          the footer build stamp; without it every deploy reads
    #                       "local".
    : "${VITE_SUPABASE_URL:?VITE_SUPABASE_URL must be set for warehouse}"
    : "${VITE_SUPABASE_ANON_KEY:?VITE_SUPABASE_ANON_KEY must be set for warehouse}"
    docker run --rm \
        -v "$WORK_HOST":/app -w /app \
        -e VITE_SUPABASE_URL="$VITE_SUPABASE_URL" \
        -e VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" \
        -e EMIT_HEADERS=1 \
        -e COMMIT_REF="$SHA" \
        node:22-alpine sh -c 'npm ci --no-audit --no-fund && npm run build'
else
    docker run --rm \
        -v "$WORK_HOST":/app -w /app \
        -e COMMIT_REF="$SHA" \
        node:22-alpine sh -c 'node scripts/build.mjs'
fi

# --- Locate the output -------------------------------------------------------
case "$SITE" in
    landing|status) BUILT="$WORK/dist/$SITE" ;;
    warehouse)      BUILT="$WORK/dist" ;;
esac
[ -d "$BUILT" ] || { echo "deploy: no build output at $BUILT" >&2; exit 1; }

# The Warehouse serves its CSP from a file inside the release, included by wildcard
# in nginx. A wildcard that matches nothing is not an error, so a build missing this
# file would serve with no CSP at all and nothing would complain. Refusing here
# fails one deploy instead; the previous release stays live.
if [ "$SITE" = warehouse ] && [ ! -f "$BUILT/headers.nginx.conf" ]; then
    echo "deploy: warehouse build has no headers.nginx.conf — refusing to publish" >&2
    record failed "build produced no CSP file"
    _done=1
    exit 1
fi

# --- Validate before publishing ----------------------------------------------
#
# A build can exit 0 and still be useless: an empty index.html, or one referencing
# a bundle that was not emitted. Checking here costs nothing and means the live
# release is never replaced by something already known to be broken.
[ -s "$BUILT/index.html" ] || {
    echo "deploy: $SITE build has no index.html — refusing to publish" >&2; exit 1; }

# Every local script/style the HTML references must actually exist in the output.
# This is what catches a half-finished bundle, which is otherwise invisible until
# a browser loads the page.
MISSING=0
for ref in $(sed -n 's/.*\(src\|href\)="\(\/[^"]*\.\(js\|css\)\)".*/\2/p' "$BUILT/index.html" | sort -u); do
    [ -f "$BUILT$ref" ] || { echo "deploy: missing asset $ref" >&2; MISSING=1; }
done
[ "$MISSING" -eq 0 ] || { echo "deploy: $SITE build is incomplete — refusing to publish" >&2; exit 1; }

# --- Publish -----------------------------------------------------------------
SHORT=$(echo "$SHA" | cut -c1-7)
DEST="$WWW_ROOT/$SITE/releases/$SHORT"
mkdir -p "$WWW_ROOT/$SITE/releases"
rm -rf "$DEST"
cp -r "$BUILT" "$DEST"

# RELATIVE symlink, and this is not stylistic. nginx reads these through a bind
# mount at a different path, so an absolute target pointing at the host layout
# does not resolve inside the container — every page 404s with nothing in the
# error log naming the cause.
cd "$WWW_ROOT/$SITE"

# What is live now, so it can be put back if the new one does not answer.
PREVIOUS=$(readlink current 2>/dev/null || true)

ln -sfn "releases/$SHORT" current.tmp
mv -Tf current.tmp current

# --- Smoke test the live site, and roll back if it fails ----------------------
#
# The swap is atomic, so this is the first moment the new release is reachable.
# Asking nginx for it through the real vhost exercises the whole path — symlink
# resolution, the docroot, the CSP include for the Warehouse — none of which the
# pre-swap checks can see.
#
# A one-second exposure to a broken release is worth far more than shipping one
# that stays broken until somebody notices.
# The Host to smoke test with. NOT derived from the site name any more: the public
# status page moved to Netlify and what this server serves is status-data, so
# "${SITE}.makebelievestudio.app" pointed at a vhost nginx no longer answers for —
# every deploy then rolled back on a 000, correctly but uselessly.
case "$SITE" in
    status)    HOST_HEADER=status-data.makebelievestudio.app ;;
    warehouse) HOST_HEADER=warehouse.makebelievestudio.app ;;
    *)         HOST_HEADER="${SITE}.makebelievestudio.app" ;;
esac

# status-data serves no page at / by design — only /detail/ and the JSON. Smoke
# testing / there would always fail, so each site names the path that proves it.
case "$SITE" in
    status) PROBE_PATH=/detail/ ;;
    *)      PROBE_PATH=/ ;;
esac

# `|| echo 000` would append to curl's own output rather than replace it, which is
# where "HTTP 000000" came from. Capture first, then default.
CODE=$(docker run --rm --network edge curlimages/curl:latest \
    -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: $HOST_HEADER" "http://edge-web-nginx-1$PROBE_PATH" 2>/dev/null) || CODE=""
[ -n "$CODE" ] || CODE=000

# /detail/ is behind Cloudflare Access, and nginx refuses anything without the
# Access assertion — so 403 from inside is the correct, healthy answer there. It
# proves nginx resolved the release and is serving it; 404 or 000 would not.
case "$SITE:$CODE" in
    status:403) CODE=200 ;;
esac

if [ "$CODE" != "200" ]; then
    echo "deploy: $SITE returned HTTP $CODE after swap" >&2
    if [ -n "$PREVIOUS" ]; then
        ln -sfn "$PREVIOUS" current.tmp
        mv -Tf current.tmp current
        echo "deploy: rolled back to $PREVIOUS" >&2
        record rolled_back "served HTTP $CODE, previous release restored"
    else
        # Nothing to go back to — the first deploy of this site. Leave it in place
        # and say so, rather than removing the symlink and serving nothing at all.
        echo "deploy: no previous release to roll back to; leaving $SHORT live" >&2
        record failed "served HTTP $CODE, no previous release to restore"
    fi
    _done=1
    exit 1
fi

echo "deploy: $SITE now serving $SHORT (HTTP $CODE)"

# --- Prune -------------------------------------------------------------------
# Keep a few to roll back to; releases are whole copies and the disk is not free.
cd "$WWW_ROOT/$SITE/releases"
ls -1t | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
    [ "$old" = "$SHORT" ] && continue
    rm -rf "$old"
done

record published "HTTP $CODE"
_done=1
