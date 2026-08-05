/*
 * Theme resolution, mirroring MBS Repair Desk's src/lib/useTheme.ts: a stored
 * preference wins, otherwise follow the system.
 *
 * Loaded synchronously from <head>, NOT inline and NOT deferred. Two reasons, and
 * both matter:
 *
 *   - The CSP is `script-src 'self'` with no 'unsafe-inline' (see
 *     scripts/emit-headers.mjs in the Repair Desk repo, which generates the same
 *     policy for these pages). An inline theme script would simply be blocked.
 *   - Deferring it would let the page paint in the light palette first and then
 *     snap to dark, which is worse than no theming at all on a bench screen.
 *
 * Storage key is deliberately distinct from either app's. The Repair Desk explains
 * why: same browser, separate sites, and someone may well want the bench dark and
 * the desk light.
 */
;(function () {
  var KEY = 'mbs-www-theme'

  function preferred() {
    try {
      var stored = localStorage.getItem(KEY)
      if (stored === 'light' || stored === 'dark') return stored
    } catch (e) {
      // Private mode, or storage disabled. Fall through to the system preference
      // rather than letting the whole page fail to render.
    }
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
  }

  function apply(theme) {
    document.documentElement.classList.toggle('dark', theme === 'dark')
    try {
      localStorage.setItem(KEY, theme)
    } catch (e) {
      // Not fatal: the theme still applies for this page view.
    }
  }

  apply(preferred())

  // The toggle only exists once the body has parsed, so wire it up then. The
  // palette itself is already correct by this point.
  document.addEventListener('DOMContentLoaded', function () {
    var button = document.querySelector('[data-theme-toggle]')
    if (!button) return

    function label() {
      var dark = document.documentElement.classList.contains('dark')
      button.textContent = dark ? '☀' : '☾'
      button.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme')
    }

    label()
    button.addEventListener('click', function () {
      apply(document.documentElement.classList.contains('dark') ? 'light' : 'dark')
      label()
    })
  })
})()
