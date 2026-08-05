# Security headers for the STATIC sites (landing, status).
#
# Hand-written rather than generated, unlike the Warehouse app's, because these
# pages call no API at all — `connect-src 'self'` is the whole story, and there is
# no VITE_SUPABASE_URL to derive anything from. The Warehouse includes its own
# generated file instead; see warehouse.conf.
#
# `always` on every directive: without it nginx omits these on non-2xx responses,
# so a 404 would be served with no CSP and no X-Frame-Options.

add_header X-Frame-Options "DENY" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header Permissions-Policy "camera=(), geolocation=(), microphone=(), payment=(), usb=(), interest-cohort=()" always;

# No 'unsafe-inline' in script-src: theme.js, status.js and notice.js are all
# external files precisely so this can stay strict.
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'; form-action 'self'" always;

# Re-stated because a location block with its own add_header discards inherited
# ones — nginx replaces the whole set rather than merging. Any location that adds
# a header must include this file again.
add_header Cache-Control $mbs_cache always;
