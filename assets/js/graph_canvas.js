// Animated discrete-graph background for the landing hero: nodes drift on
// sine wobble, edges form by proximity, and amber pulses travel toward a
// central hub (You). Colors come from the theme's CSS custom properties,
// so it follows light/dark automatically. Renders a single static frame
// under prefers-reduced-motion.

const EDGE_DIST = 150
const PULSE_EVERY_MS = 1300
const PULSE_TRAVEL_MS = 1500

const GraphCanvas = {
  mounted() {
    this._cleanup = startGraphCanvas(this.el)
  },

  destroyed() {
    if (this._cleanup) this._cleanup()
  }
}

// Framework-free entry point: works both as the engine behind the
// LiveView hook and standalone on dead-rendered pages (login), where
// app.js auto-starts any <canvas data-graph>.
function startGraphCanvas(canvas) {
  const ctx = canvas.getContext("2d")
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")
  const state = {
    ctx,
    canvas,
    reducedMotion,
    pulses: [],
    lastPulse: 0,
    mouse: null,
    dark: false,
    colors: {},
    raf: null
  }

  const readColors = () => {
    const css = getComputedStyle(document.documentElement)
    const hsl = (name, fallback) => `hsl(${css.getPropertyValue(name).trim() || fallback})`
    state.colors = {
      edge: hsl("--brand-azure", "210 90% 52%"),
      node: hsl("--brand-azure", "210 90% 52%"),
      hub: hsl("--brand-magenta", "330 85% 55%"),
      pulse: hsl("--brand-lime", "90 75% 40%")
    }
    state.dark = document.documentElement.classList.contains("dark")
  }

  const resize = () => {
    const rect = canvas.parentElement.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    state.w = rect.width
    state.h = rect.height
    canvas.width = Math.round(state.w * dpr)
    canvas.height = Math.round(state.h * dpr)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  }

  const seed = () => {
    const count = Math.max(24, Math.min(70, Math.floor((state.w * state.h) / 26000)))
    state.nodes = Array.from({length: count}, () => ({
      x: Math.random() * state.w,
      y: Math.random() * state.h,
      vx: (Math.random() - 0.5) * 0.18,
      vy: (Math.random() - 0.5) * 0.18,
      phase: Math.random() * Math.PI * 2,
      wobble: 0.3 + Math.random() * 0.7
    }))
    state.hub = {x: state.w * 0.72, y: state.h * 0.42, flash: 0}
  }

  const step = (t) => {
    for (const n of state.nodes) {
      n.x += n.vx + Math.sin(t / 2400 + n.phase) * 0.08 * n.wobble
      n.y += n.vy + Math.cos(t / 3000 + n.phase) * 0.08 * n.wobble

      if (state.mouse) {
        const dx = n.x - state.mouse.x
        const dy = n.y - state.mouse.y
        const d2 = dx * dx + dy * dy
        if (d2 < 120 * 120 && d2 > 0.01) {
          const d = Math.sqrt(d2)
          const f = ((120 - d) / 120) * 0.35
          n.x += (dx / d) * f
          n.y += (dy / d) * f
        }
      }

      if (n.x < -20) n.x = state.w + 20
      if (n.x > state.w + 20) n.x = -20
      if (n.y < -20) n.y = state.h + 20
      if (n.y > state.h + 20) n.y = -20
    }

    if (t - state.lastPulse > PULSE_EVERY_MS && state.nodes.length > 0) {
      state.lastPulse = t
      const from = state.nodes[Math.floor(Math.random() * state.nodes.length)]
      state.pulses.push({from, start: t})
    }

    state.pulses = state.pulses.filter((p) => t - p.start < PULSE_TRAVEL_MS)
    state.hub.flash = Math.max(0, state.hub.flash - 0.04)

    for (const p of state.pulses) {
      if (t - p.start >= PULSE_TRAVEL_MS - 16) state.hub.flash = 1
    }
  }

  const draw = (t) => {
    const {colors, nodes, hub} = state
    ctx.clearRect(0, 0, state.w, state.h)

    const edgeAlpha = state.dark ? 0.32 : 0.22
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const dx = nodes[i].x - nodes[j].x
        const dy = nodes[i].y - nodes[j].y
        const d = Math.hypot(dx, dy)
        if (d < EDGE_DIST) {
          ctx.globalAlpha = (1 - d / EDGE_DIST) * edgeAlpha
          ctx.strokeStyle = colors.edge
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.moveTo(nodes[i].x, nodes[i].y)
          ctx.lineTo(nodes[j].x, nodes[j].y)
          ctx.stroke()
        }
      }
    }

    ctx.globalAlpha = state.dark ? 0.8 : 0.6
    ctx.fillStyle = colors.node
    for (const n of nodes) {
      ctx.beginPath()
      ctx.arc(n.x, n.y, 1.6, 0, Math.PI * 2)
      ctx.fill()
    }

    ctx.globalAlpha = state.dark ? 0.1 : 0.07
    ctx.strokeStyle = colors.hub
    for (const n of nodes) {
      ctx.beginPath()
      ctx.moveTo(n.x, n.y)
      ctx.lineTo(hub.x, hub.y)
      ctx.stroke()
    }

    for (const p of state.pulses) {
      const k = Math.min(1, (t - p.start) / PULSE_TRAVEL_MS)
      const ease = k * k * (3 - 2 * k)
      const x = p.from.x + (hub.x - p.from.x) * ease
      const y = p.from.y + (hub.y - p.from.y) * ease
      ctx.globalAlpha = 0.9
      ctx.fillStyle = colors.pulse
      ctx.beginPath()
      ctx.arc(x, y, 2.2, 0, Math.PI * 2)
      ctx.fill()
    }

    ctx.globalAlpha = 1
    ctx.save()
    ctx.shadowColor = colors.hub
    ctx.shadowBlur = 18 + hub.flash * 22
    ctx.fillStyle = colors.hub
    ctx.beginPath()
    ctx.arc(hub.x, hub.y, 4.5 + hub.flash * 2.5, 0, Math.PI * 2)
    ctx.fill()
    ctx.restore()

    ctx.globalAlpha = 1
  }

  const tick = (t) => {
    step(t)
    draw(t)
    state.raf = requestAnimationFrame(tick)
  }

  readColors()
  resize()
  seed()

  const resizeObserver = new ResizeObserver(() => {
    resize()
    seed()
    if (reducedMotion.matches) draw(0)
  })
  resizeObserver.observe(canvas.parentElement)

  const themeObserver = new MutationObserver(() => {
    readColors()
    if (reducedMotion.matches) draw(0)
  })
  themeObserver.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["class"]
  })

  const onPointerMove = (e) => {
    const rect = canvas.getBoundingClientRect()
    state.mouse = {x: e.clientX - rect.left, y: e.clientY - rect.top}
  }
  const onPointerLeave = () => (state.mouse = null)
  canvas.parentElement.addEventListener("pointermove", onPointerMove)
  canvas.parentElement.addEventListener("pointerleave", onPointerLeave)

  if (reducedMotion.matches) {
    draw(0)
  } else {
    state.raf = requestAnimationFrame(tick)
  }

  return () => {
    cancelAnimationFrame(state.raf)
    resizeObserver.disconnect()
    themeObserver.disconnect()
    canvas.parentElement.removeEventListener("pointermove", onPointerMove)
    canvas.parentElement.removeEventListener("pointerleave", onPointerLeave)
  }
}

export {startGraphCanvas}
export default GraphCanvas
