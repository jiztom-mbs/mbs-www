/*
 * The internal status view. Reads /detail/api/detail.json, which sits under the
 * same Cloudflare Access policy as this page.
 *
 * This one may show what the public page must not: CPU, memory and disk pressure,
 * image tags, uptimes and restart counts. That split is the reason there are two
 * files rather than one with a flag — a single file guarded only at the page level
 * would still be fetchable directly.
 *
 * Same honesty rule as the public page: stale or unreachable data reads as
 * unknown, never as healthy.
 */
;(function () {
  // Empty when served from the server itself, where these are same-origin paths.
  // Replaced at build time with the data host when the page is published to
  // Netlify, which cannot serve them — see scripts/build.mjs.
  var API_BASE = '__STATUS_API__'.indexOf('__') === 0 ? '' : '__STATUS_API__'

  var REFRESH_MS = 15000
  var STALE_MS = 90000

  var summaryEl = document.getElementById('summary')
  var hostEl = document.getElementById('host')
  var containersEl = document.getElementById('containers')
  var deploysEl = document.getElementById('deploys')
  var checkedEl = document.getElementById('checked')

  function relative(iso) {
    var then = Date.parse(iso)
    if (isNaN(then)) return 'unknown'
    var secs = Math.max(0, Math.round((Date.now() - then) / 1000))
    if (secs < 60) return secs + 's ago'
    if (secs < 3600) return Math.round(secs / 60) + 'm ago'
    if (secs < 86400) return Math.round(secs / 3600) + 'h ago'
    return Math.round(secs / 86400) + 'd ago'
  }

  function el(tag, className, text) {
    var n = document.createElement(tag)
    if (className) n.className = className
    if (text !== undefined) n.textContent = text
    return n
  }

  /**
   * A usage meter. Thresholds are on the bar's own class rather than inline style
   * so the palette stays in CSS, and the number is always shown as text beside it —
   * a bar alone is not readable to someone using a screen reader.
   */
  function meter(label, used, total, unit, pct) {
    var card = el('div', 'card meter')
    card.appendChild(el('span', 'meter-label', label))

    var value = el('span', 'meter-value')
    value.textContent =
      total != null ? used + ' / ' + total + ' ' + unit : pct != null ? pct + '%' : '—'
    card.appendChild(value)

    var track = el('div', 'meter-track')
    var fill = el('div', 'meter-fill')
    var safe = typeof pct === 'number' && isFinite(pct) ? Math.max(0, Math.min(100, pct)) : 0
    fill.style.width = safe + '%'
    // Banding, not a gradient: "how close to trouble" is what a glance needs.
    if (safe >= 90) fill.classList.add('meter-fill--critical')
    else if (safe >= 75) fill.classList.add('meter-fill--warn')
    track.appendChild(fill)
    track.setAttribute('role', 'img')
    track.setAttribute('aria-label', label + ' ' + safe + ' percent used')
    card.appendChild(track)

    card.appendChild(el('span', 'faint', safe + '% used'))
    return card
  }

  function renderHost(host) {
    hostEl.textContent = ''
    if (!host) {
      hostEl.appendChild(el('div', 'card', 'Host metrics unavailable.'))
      return
    }
    hostEl.appendChild(meter('CPU', null, null, '', host.cpu_pct))
    hostEl.appendChild(
      meter('Memory', host.mem_used_gb, host.mem_total_gb, 'GiB', host.mem_pct),
    )
    hostEl.appendChild(meter('Disk', host.disk_used_gb, host.disk_total_gb, 'GB', host.disk_pct))

    var extra = el('div', 'card meter')
    extra.appendChild(el('span', 'meter-label', 'Load / uptime'))
    extra.appendChild(el('span', 'meter-value', host.load1 != null ? String(host.load1) : '—'))
    extra.appendChild(el('span', 'faint', host.uptime ? 'up ' + host.uptime : ''))
    hostEl.appendChild(extra)
  }

  function renderContainers(list) {
    containersEl.textContent = ''
    if (!list || list.length === 0) {
      var tr = el('tr')
      var td = el('td', 'muted', 'No container data.')
      td.colSpan = 5
      tr.appendChild(td)
      containersEl.appendChild(tr)
      return
    }

    list.forEach(function (c) {
      var tr = el('tr', c.state === 'up' ? '' : 'row-down')
      tr.appendChild(el('td', 'service-name', c.name))

      var state = el('td')
      var wrap = el('span', 'service-state state-' + (c.state === 'up' ? 'up' : 'down'))
      wrap.appendChild(el('span', 'dot'))
      wrap.appendChild(el('span', null, c.state))
      state.appendChild(wrap)
      tr.appendChild(state)

      tr.appendChild(el('td', 'mono', c.uptime || '—'))
      tr.appendChild(el('td', 'mono', c.restarts != null ? String(c.restarts) : '—'))
      tr.appendChild(el('td', 'mono faint', c.image || '—'))
      containersEl.appendChild(tr)
    })
  }

  /**
   * What is live, and how the last attempt ended — two facts, not one.
   *
   * They disagree exactly when it matters most. A rolled-back deploy leaves the
   * previous good release serving while the last attempt reads `failed`: reporting
   * only the log would imply the site is down when it is not, and reporting only
   * the symlink would hide that a deploy broke.
   */
  function renderDeploys(list) {
    deploysEl.textContent = ''
    if (!list || list.length === 0) {
      deploysEl.appendChild(el('div', 'card', 'No deploys recorded yet.'))
      return
    }

    list.forEach(function (d) {
      var failed = d.status === 'failed' || d.status === 'rolled_back'
      var card = el('div', 'card deploy' + (failed ? ' state-down' : ''))

      var title = el('span', 'card-title')
      title.appendChild(el('span', null, d.site))

      var badge = el('span', 'deploy-status deploy-status--' + (d.status || 'unknown'))
      badge.textContent =
        d.status === 'published' ? 'live'
        : d.status === 'rolled_back' ? 'rolled back'
        : d.status === 'failed' ? 'failed'
        : 'unknown'
      title.appendChild(badge)
      card.appendChild(title)

      // The live release is the headline: it is what visitors are being served.
      var live = el('p', 'deploy-line')
      live.appendChild(el('span', 'faint', 'serving '))
      live.appendChild(el('span', 'mono', d.live || '—'))
      if (d.at) {
        live.appendChild(el('span', 'faint', '  ·  last deploy ' + relative(d.at)))
      }
      card.appendChild(live)

      // Only worth saying when the attempt differs from what is live — otherwise
      // it repeats the line above.
      if (failed && d.ref && d.ref !== d.live) {
        var attempt = el('p', 'deploy-line')
        attempt.appendChild(el('span', 'faint', 'attempted '))
        attempt.appendChild(el('span', 'mono', d.ref))
        card.appendChild(attempt)
      }

      if (d.detail) card.appendChild(el('p', 'faint', d.detail))
      deploysEl.appendChild(card)
    })
  }

  function unknown(message) {
    summaryEl.textContent = message
    hostEl.textContent = ''
    hostEl.appendChild(el('div', 'card', 'Unavailable.'))
    renderContainers(null)
    renderDeploys(null)
    checkedEl.textContent = ''
  }

  function poll() {
    fetch(API_BASE + '/detail/api/detail.json', { cache: 'no-store' })
      .then(function (r) {
        // 302 to a Cloudflare login means the Access session has lapsed. Say so,
        // rather than showing an empty page that looks like an outage.
        if (r.redirected) throw new Error('access')
        if (!r.ok) throw new Error('HTTP ' + r.status)
        return r.json()
      })
      .then(function (data) {
        var age = Date.now() - Date.parse(data.checked_at)
        if (!(age >= 0) || age > STALE_MS) {
          unknown('Data is out of date — the collector has stopped reporting.')
          return
        }
        var down = (data.containers || []).filter(function (c) {
          return c.state !== 'up'
        }).length
        summaryEl.textContent =
          down === 0
            ? 'All containers running.'
            : down === 1
              ? '1 container is not running.'
              : down + ' containers are not running.'
        renderHost(data.host)
        renderContainers(data.containers)
        renderDeploys(data.deploys)
        checkedEl.textContent = 'Checked ' + relative(data.checked_at)
      })
      .catch(function (e) {
        unknown(
          e && e.message === 'access'
            ? 'Your session has expired. Reload to sign in again.'
            : 'Cannot reach the status collector.',
        )
      })
  }

  poll()
  setInterval(poll, REFRESH_MS)
})()
