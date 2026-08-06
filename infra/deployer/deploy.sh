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
    exit 1
fi

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
ln -sfn "releases/$SHORT" current.tmp
mv -Tf current.tmp current

echo "deploy: $SITE now serving $SHORT"

# --- Prune -------------------------------------------------------------------
# Keep a few to roll back to; releases are whole copies and the disk is not free.
cd "$WWW_ROOT/$SITE/releases"
ls -1t | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
    [ "$old" = "$SHORT" ] && continue
    rm -rf "$old"
done

mkdir -p "$DEPLOY_ROOT/log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $SITE $SHORT" >> "$DEPLOY_ROOT/log/deploys.log"
