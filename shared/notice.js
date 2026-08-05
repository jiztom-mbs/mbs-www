/*
 * "You may be looking for the other site."
 *
 * makebelievestudio.app is where the studio's systems live; makebelievestudio.com
 * is the address a customer knows. Someone who half-remembers the name can land
 * here and see a page full of internal tools with no idea they are in the wrong
 * place, so say so — once, clearly, without blocking anyone.
 *
 * A banner rather than a modal, deliberately. A modal would interrupt every staff
 * member on every new browser and phone, and a lost customer can dismiss a modal
 * as reflexively as a banner. This one is high contrast and above the header, so
 * it is the first thing on the page either way, and it never covers content.
 *
 * Dismissal is remembered so it appears once per browser. Loaded deferred, unlike
 * theme.js — a banner appearing a frame late is fine, whereas the wrong palette
 * appearing a frame late is not.
 */
;(function () {
  var KEY = 'mbs-www-site-notice'
  var TARGET = 'https://www.makebelievestudio.com'

  function dismissed() {
    try {
      return localStorage.getItem(KEY) === 'dismissed'
    } catch (e) {
      // Private mode or storage disabled: show it. Better a repeated notice than
      // a customer who never sees it.
      return false
    }
  }

  function remember() {
    try {
      localStorage.setItem(KEY, 'dismissed')
    } catch (e) {
      /* nothing to do; the notice simply returns next visit */
    }
  }

  if (dismissed()) return

  var bar = document.createElement('aside')
  bar.className = 'site-notice'
  // A region rather than an alert: alert interrupts a screen reader mid-sentence,
  // and this is informational, not urgent.
  bar.setAttribute('role', 'region')
  bar.setAttribute('aria-label', 'Site notice')

  var text = document.createElement('p')
  text.className = 'site-notice-text'
  text.appendChild(document.createTextNode('This is Make Believe Studio’s systems site. '))

  var link = document.createElement('a')
  link.href = TARGET
  link.className = 'site-notice-link'
  link.textContent = 'Looking for the studio? Go to makebelievestudio.com'
  text.appendChild(link)

  var close = document.createElement('button')
  close.type = 'button'
  close.className = 'site-notice-close'
  close.setAttribute('aria-label', 'Dismiss this notice')
  close.textContent = '×'
  close.addEventListener('click', function () {
    remember()
    bar.remove()
  })

  bar.appendChild(text)
  bar.appendChild(close)
  document.body.insertBefore(bar, document.body.firstChild)
})()
