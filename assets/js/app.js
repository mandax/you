// You — Identity & Access Management

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"

// ── Auto-dismiss flash toasts ──────────────────────────────────
// Works on both LiveView and controller (dead-view) pages: scan the initial
// DOM and observe later insertions (LiveView), then fade + hide each toast.
const FLASH_TIMEOUT_MS = 5000

function armFlash(el) {
  if (el.dataset.flashArmed) return
  el.dataset.flashArmed = "1"
  setTimeout(() => {
    el.style.transition = "opacity 300ms ease, transform 300ms ease"
    el.style.opacity = "0"
    el.style.transform = "translateY(-6px)"
    setTimeout(() => {
      el.style.display = "none"
    }, 320)
  }, FLASH_TIMEOUT_MS)
}

function scanFlashes(root) {
  if (root.matches && root.matches("[data-flash]")) armFlash(root)
  root.querySelectorAll && root.querySelectorAll("[data-flash]").forEach(armFlash)
}

document.addEventListener("DOMContentLoaded", () => scanFlashes(document))

// Start graph canvases on dead-rendered pages (login) — LiveView pages use
// the GraphCanvas hook instead.
import {startGraphCanvas} from "./graph_canvas"

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("canvas[data-graph]").forEach(startGraphCanvas)
})

new MutationObserver((mutations) => {
  for (const m of mutations) {
    for (const node of m.addedNodes) {
      if (node.nodeType === 1) scanFlashes(node)
    }
  }
}).observe(document.documentElement, {childList: true, subtree: true})
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
// Hooks colocated with the components that use them — see
// lib/you_web/components/base/. Written at compile time, so `mix compile`
// must run before the bundler.
import {hooks as colocatedHooks} from "phoenix-colocated/you"

// ── Theme Toggle Hook ────────────────────────────

const ThemeToggle = {
  mounted() {
    this.el.addEventListener("click", () => {
      const isDark = document.documentElement.classList.contains("dark")
      setTheme(isDark ? "light" : "dark")
    })
  },
}

// ── Theme helpers ────────────────────────────────

function setTheme(theme) {
  localStorage.setItem("you-theme", theme)
  applyTheme(theme)
}

function applyTheme(theme) {
  document.documentElement.classList.toggle("dark", theme === "dark")
}

// Listen for system preference changes (only if no explicit preference is set)
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", e => {
  if (!localStorage.getItem("you-theme")) {
    applyTheme(e.matches ? "dark" : "light")
  }
})

// LiveView Hooks
import GraphCanvas from "./graph_canvas"

const Hooks = {
  ThemeToggle,
  GraphCanvas,
  CopyToClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.clipboardText
        navigator.clipboard.writeText(text).then(() => {
          console.log("Copied to clipboard:", text)
        }).catch(err => {
          console.error("Failed to copy:", err)
        })
      })
    }
  }
}

// ── WebAuthn (Passkey) —────────────────────────────

import {registerPasskey, authenticatePasskey} from "./webauthn"
import {youAlert, youPrompt, installConfirmInterceptor} from "./confirm"

// Replace native data-confirm prompts with the shadcn confirm modal, app-wide.
installConfirmInterceptor()

// Auto-attach the "Sign in with a passkey" button on the login page
document.addEventListener("DOMContentLoaded", () => {
  const btn = document.getElementById("passkey-login")
  if (!btn) return
  btn.addEventListener("click", async () => {
    btn.disabled = true
    try {
      const email = document.querySelector("input[name='user[email]']")?.value || undefined
      await authenticatePasskey(
        btn.dataset.startUrl || "/users/log-in/passkey/start",
        btn.dataset.finishUrl || "/users/log-in/passkey/finish",
        email,
      )
    } catch (err) {
      console.error("Passkey sign-in failed:", err)
      youAlert(err.message || "Passkey sign-in failed. Please try again.", {title: "Passkey sign-in"})
    } finally {
      btn.disabled = false
    }
  })
})

// Auto-attach the "Add passkey" button on the settings page
document.addEventListener("DOMContentLoaded", () => {
  const btn = document.getElementById("register-passkey")
  if (!btn) return
  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
  btn.addEventListener("click", async () => {
    const label = await youPrompt("Name this passkey", {
      okLabel: "Add passkey",
      placeholder: "e.g. MacBook Touch ID (optional)",
    })
    if (label === null) return // cancelled

    btn.disabled = true
    btn.textContent = "Registering…"
    try {
      const result = await registerPasskey(
        btn.dataset.startUrl || "/users/settings/passkeys/register/start",
        "/users/settings/passkeys/register/finish",
        csrfToken,
        label || undefined,
      )
      console.log("Passkey registered:", result)
      window.location.reload()
    } catch (err) {
      console.error("Passkey registration failed:", err)
      youAlert(err.message || "Passkey registration failed. Please try again.", {title: "Add passkey"})
    } finally {
      btn.disabled = false
      btn.textContent = "Add passkey"
    }
  })
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...Hooks, ...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#8b5cf6"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
