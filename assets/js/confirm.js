// Shadcn-styled confirm / alert modals that replace the native window.confirm
// and alert popups — including the `data-confirm` dialogs that LiveView and
// phoenix_html links trigger, via a single capture-phase interceptor.

let dialogEl, titleEl, bodyEl, cancelBtn, okBtn, resolver

const OK_BASE =
  "inline-flex h-9 items-center justify-center rounded-md px-4 text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"

function ensureDialog() {
  if (dialogEl) return

  dialogEl = document.createElement("dialog")
  dialogEl.className =
    "m-auto w-full max-w-sm rounded-lg border border-border bg-popover p-6 text-popover-foreground shadow-lg backdrop:bg-black/60 backdrop:backdrop-blur-sm open:animate-rise-in"
  dialogEl.innerHTML = `
    <h2 data-part="title" class="text-base font-semibold leading-snug tracking-tight"></h2>
    <p data-part="body" class="mt-2 text-sm text-muted-foreground"></p>
    <div class="mt-6 flex items-center justify-end gap-2">
      <button data-part="cancel" type="button"
        class="inline-flex h-9 items-center justify-center rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent hover:text-accent-foreground"></button>
      <button data-part="ok" type="button" class="${OK_BASE}"></button>
    </div>`
  document.body.appendChild(dialogEl)

  titleEl = dialogEl.querySelector('[data-part="title"]')
  bodyEl = dialogEl.querySelector('[data-part="body"]')
  cancelBtn = dialogEl.querySelector('[data-part="cancel"]')
  okBtn = dialogEl.querySelector('[data-part="ok"]')

  cancelBtn.addEventListener("click", () => close(false))
  okBtn.addEventListener("click", () => close(true))
  // Escape / backdrop close = cancel
  dialogEl.addEventListener("cancel", (e) => {
    e.preventDefault()
    close(false)
  })
  dialogEl.addEventListener("click", (e) => {
    if (e.target === dialogEl) close(false)
  })
}

function close(result) {
  if (dialogEl.open) dialogEl.close()
  if (resolver) {
    const r = resolver
    resolver = null
    r(result)
  }
}

function open({title, body, okLabel, cancelLabel, danger}) {
  ensureDialog()
  titleEl.textContent = title
  bodyEl.textContent = body || ""
  bodyEl.style.display = body ? "" : "none"

  okBtn.textContent = okLabel
  okBtn.className =
    OK_BASE +
    (danger
      ? " bg-destructive text-destructive-foreground hover:bg-destructive/90"
      : " bg-primary text-primary-foreground hover:bg-primary/90")

  cancelBtn.style.display = cancelLabel === null ? "none" : ""
  if (cancelLabel !== null) cancelBtn.textContent = cancelLabel

  return new Promise((res) => {
    resolver = res
    dialogEl.showModal()
    okBtn.focus()
  })
}

export function youConfirm(message, {okLabel = "Confirm", danger = true} = {}) {
  return open({title: message, body: null, okLabel, cancelLabel: "Cancel", danger})
}

export function youAlert(message, {title = "Heads up"} = {}) {
  return open({title, body: message, okLabel: "OK", cancelLabel: null, danger: false})
}

// Replace the native data-confirm dialog everywhere. We intercept the click in
// the capture phase (before LiveView / phoenix_html handle it), show our modal,
// and — if confirmed — re-dispatch the click with data-confirm stripped so the
// original action proceeds without the browser prompt.
export function installConfirmInterceptor() {
  document.addEventListener(
    "click",
    (e) => {
      const el = e.target.closest("[data-confirm]")
      if (!el) return

      e.preventDefault()
      e.stopImmediatePropagation()

      const message = el.getAttribute("data-confirm")
      youConfirm(message).then((ok) => {
        if (!ok) return
        el.removeAttribute("data-confirm")
        el.click()
        el.setAttribute("data-confirm", message)
      })
    },
    true
  )
}
