/*
 * Renders /api/status.json, which a collector on the server rewrites every 30s.
 *
 * The page never talks to Docker. It reads a static JSON file that has already
 * been reduced to labels and up/down — see infra/collector. Anything richer
 * (versions, image tags, ports) is reconnaissance on a public page, so it never
 * leaves the host.
 *
 * The rule this file exists to honour: never show green unless the data says so
 * and is fresh. A status page that fails to green is worse than none at all,
 * because it is confidently wrong at exactly the moment someone is checking.
 */
;(function () {
  // Empty when served from the server itself, where these are same-origin paths.
  // Replaced at build time with the data host when the page is published to
  // Netlify, which cannot serve them — see scripts/build.mjs.
  var API_BASE = '__STATUS_API__'.indexOf('__') === 0 ? '' : '__STATUS_API__'

  var REFRESH_MS = 30000
  // Older than this and the collector has stopped, whatever the file says.
  var STALE_MS = 150000

  var servicesEl = document.getElementById('services')
  var summaryEl = document.getElementById('summary')
  var checkedEl = document.getElementById('checked')

  function relative(iso) {
    var then = Date.parse(iso)
    if (isNaN(then)) return 'at an unknown time'
    var secs = Math.max(0, Math.round((Date.now() - then) / 1000))
    if (secs < 60) return secs + 's ago'
    if (secs < 3600) return Math.round(secs / 60) + 'm ago'
    return Math.round(secs / 3600) + 'h ago'
  }

  function row(name, state) {
    var li = document.createElement('li')
    li.className = 'card service state-' + state

    var label = document.createElement('span')
    label.className = 'service-name'
    label.textContent = name

    var wrap = document.createElement('span')
    wrap.className = 'service-state'

    var dot = document.createElement('span')
    dot.className = 'dot'

    var word = document.createElement('span')
    word.textContent = state

    wrap.appendChild(dot)
    wrap.appendChild(word)
    li.appendChild(label)
    li.appendChild(wrap)
    return li
  }

  function render(data, stale) {
    var services = (data && data.services) || []
    servicesEl.textContent = ''

    if (services.length === 0) {
      servicesEl.appendChild(row('Status unavailable', 'unknown'))
      summaryEl.textContent = 'Cannot reach the status collector.'
      checkedEl.textContent = ''
      return
    }

    var down = 0
    for (var i = 0; i < services.length; i++) {
      var s = services[i]
      // Stale data is reported as unknown rather than as its last known value.
      var state = stale ? 'unknown' : s.state === 'up' ? 'up' : 'down'
      if (state === 'down') down++
      servicesEl.appendChild(row(s.name, state))
    }

    if (stale) {
      summaryEl.textContent = 'Status is out of date — the collector has stopped reporting.'
    } else if (down === 0) {
      summaryEl.textContent = 'All systems normal.'
    } else {
      summaryEl.textContent =
        down === 1 ? '1 service is down.' : down + ' services are down.'
    }

    checkedEl.textContent = data.checked_at ? 'Checked ' + relative(data.checked_at) : ''
  }

  function poll() {
    // cache: no-store so a refresh is a real one. nginx also sends no-store, but
    // relying on only one of the two is how a status page ends up showing an
    // hour-old snapshot.
    fetch(API_BASE + '/api/status.json', { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status)
        return r.json()
      })
      .then(function (data) {
        var age = Date.now() - Date.parse(data.checked_at)
        render(data, !(age >= 0) || age > STALE_MS)
      })
      .catch(function () {
        // Unreachable, unparseable, or served an error. All of them mean the same
        // thing to a reader: we do not know.
        render(null, true)
      })
  }

  poll()
  setInterval(poll, REFRESH_MS)
})()
