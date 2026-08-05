# Setting up the web tier on mbs-ub

Everything here runs in Docker. **Nothing is installed on the host** — no nginx, no
Node. `nginx:alpine` is an image Docker pulls; the host stays as it is.

The only commands needing `sudo` are the three `mkdir`s, because `/srv` is
root-owned. Everything after that runs as `jiztom`, who is already in the `docker`
group.

## 1. Directories

```bash
sudo mkdir -p /srv/edge-web /srv/www /srv/status-data/{public,detail}
sudo chown -R jiztom:jiztom /srv/edge-web /srv/www /srv/status-data
```

Layout this creates:

```
/srv/edge-web/                 compose + nginx config (this repo's infra/edge-web)
/srv/www/<site>/releases/<sha> a build
/srv/www/<site>/current        symlink -> the live release
/srv/status-data/public/       status.json   (public)
/srv/status-data/detail/       detail.json   (behind Cloudflare Access)
```

`status-data` sits **outside** `/srv/www` on purpose. A deploy replaces `current`
wholesale, so a collector writing into a release would have its output deleted by
the next deploy.

## 2. Config onto the server

```bash
git clone git@git.makebelievestudio.app:MakeBelieveStudio/mbs-www.git ~/mbs-www
cp -r ~/mbs-www/infra/edge-web/. /srv/edge-web/
```

Or `scp -r infra/edge-web/. mbs-ub:/srv/edge-web/` from your laptop. Cloning is
better — updating the config later becomes `git pull` plus a reload.

## 3. Start it

```bash
cd /srv/edge-web
docker compose up -d
docker compose ps
```

Expect `edge-web-nginx-1` healthy. It joins the existing external `edge` network
and publishes **no ports** — nothing on this box should be reachable except through
the tunnel.

If it exits immediately:

```bash
docker compose logs --tail 20
```

## 4. Check it before touching DNS

Serving is testable without Cloudflare — ask another container on `edge` for each
hostname:

```bash
docker run --rm --network edge curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: www.makebelievestudio.app' http://edge-web-nginx-1/
```

Before any site is deployed this returns 404, which is correct — nginx is up, the
docroot is empty. A 000 or a connection error means the container is not running.

## 5. Cloudflare

The tunnel is token-based and remotely managed, so routes live in the dashboard,
not in a file on the server. Zero Trust → Networks → Tunnels → your tunnel →
Public Hostnames. Add three, all pointing at the same service:

| Hostname | Service |
| --- | --- |
| `www.makebelievestudio.app` | `http://edge-web-nginx-1:80` |
| `status.makebelievestudio.app` | `http://edge-web-nginx-1:80` |
| `warehouse.makebelievestudio.app` | `http://edge-web-nginx-1:80` |

nginx picks the site from the `Host` header, which cloudflared passes through. DNS
records are created by the tunnel.

## 6. Access on the detailed status only

Zero Trust → Access → Applications → Add → Self-hosted:

- Domain `status.makebelievestudio.app`, **path `detail`**
- Policy: Allow → Include → *Emails ending in* `@makebelievestudio.com`

Leave `www` and the public `status` page with no application in front of them.

The path matters. `/detail/` holds both the page and the JSON it reads
(`/detail/api/detail.json`), so one policy covers both. A policy on the page alone
would leave the data readable by anyone who guessed the URL — and the data is the
sensitive half.

## Operating it

Reload after a config change, without dropping connections:

```bash
cd /srv/edge-web && git -C ~/mbs-www pull && cp -r ~/mbs-www/infra/edge-web/. /srv/edge-web/
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
```

Always `nginx -t` first. A reload with a broken config is refused and the running
server carries on, but a `restart` with a broken config leaves you with nothing.

Roll a site back — releases are kept, so this is instant:

```bash
ls -l /srv/www/warehouse/releases/
ln -sfn /srv/www/warehouse/releases/<older-sha> /srv/www/warehouse/current.tmp
mv -Tf /srv/www/warehouse/current.tmp /srv/www/warehouse/current
```

No nginx reload needed — it resolves the symlink per request.

## Known behaviours, so they do not look like faults

- **An unknown `Host` gets no reply at all** (444, connection closed). Anything
  reaching nginx without a configured hostname came from a scanner or stale DNS,
  and neither deserves a response confirming a server is here.
- **The Warehouse vhost tolerates having no release.** Its CSP file is included by
  wildcard, so nginx starts whether or not the Warehouse has ever been deployed.
  An earlier literal include meant a missing Warehouse release stopped nginx
  entirely and took the landing and status sites down with it.
- **`disable_symlinks off` is required**, because `current` is a symlink. Without
  it every page 404s and nothing in the error log mentions symlinks.
