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
    this.ctx = this.el.getContext("2d")
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.pulses = []
    this.lastPulse = 0
    this.mouse = null

    this.readColors()
    this.resize()
    this.seed()

    this.resizeObserver = new ResizeObserver(() => {
      this.resize()
      this.seed()
      if (this.reducedMotion.matches) this.draw(0)
    })
    this.resizeObserver.observe(this.el.parentElement)

    this.themeObserver = new MutationObserver(() => {
      this.readColors()
      if (this.reducedMotion.matches) this.draw(0)
    })
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class"]
    })

    this.el.parentElement.addEventListener("pointermove", (e) => {
      const rect = this.el.getBoundingClientRect()
      this.mouse = {x: e.clientX - rect.left, y: e.clientY - rect.top}
    })
    this.el.parentElement.addEventListener("pointerleave", () => (this.mouse = null))

    if (!this.reducedMotion.matches) {
      this.raf = requestAnimationFrame((t) => this.tick(t))
    } else {
      this.draw(0)
    }
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    this.resizeObserver.disconnect()
    this.themeObserver.disconnect()
  },

  readColors() {
    const css = getComputedStyle(document.documentElement)
    const hsl = (name, fallback) => `hsl(${css.getPropertyValue(name).trim() || fallback})`
    this.colors = {
      edge: hsl("--brand-azure", "210 90% 52%"),
      node: hsl("--brand-azure", "210 90% 52%"),
      hub: hsl("--primary", "262 83% 58%"),
      pulse: hsl("--signal-warn", "38 92% 45%")
    }
    this.dark = document.documentElement.classList.contains("dark")
  },

  resize() {
    const rect = this.el.parentElement.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    this.w = rect.width
    this.h = rect.height
    this.el.width = Math.round(this.w * dpr)
    this.el.height = Math.round(this.h * dpr)
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  },

  seed() {
    const count = Math.max(24, Math.min(70, Math.floor((this.w * this.h) / 26000)))
    this.nodes = Array.from({length: count}, () => ({
      x: Math.random() * this.w,
      y: Math.random() * this.h,
      vx: (Math.random() - 0.5) * 0.18,
      vy: (Math.random() - 0.5) * 0.18,
      phase: Math.random() * Math.PI * 2,
      wobble: 0.3 + Math.random() * 0.7
    }))
    this.hub = {x: this.w * 0.72, y: this.h * 0.42, flash: 0}
  },

  tick(t) {
    this.step(t)
    this.draw(t)
    this.raf = requestAnimationFrame((nt) => this.tick(nt))
  },

  step(t) {
    for (const n of this.nodes) {
      n.x += n.vx + Math.sin(t / 2400 + n.phase) * 0.08 * n.wobble
      n.y += n.vy + Math.cos(t / 3000 + n.phase) * 0.08 * n.wobble

      if (this.mouse) {
        const dx = n.x - this.mouse.x
        const dy = n.y - this.mouse.y
        const d2 = dx * dx + dy * dy
        if (d2 < 120 * 120 && d2 > 0.01) {
          const d = Math.sqrt(d2)
          const f = ((120 - d) / 120) * 0.35
          n.x += (dx / d) * f
          n.y += (dy / d) * f
        }
      }

      if (n.x < -20) n.x = this.w + 20
      if (n.x > this.w + 20) n.x = -20
      if (n.y < -20) n.y = this.h + 20
      if (n.y > this.h + 20) n.y = -20
    }

    if (t - this.lastPulse > PULSE_EVERY_MS && this.nodes.length > 0) {
      this.lastPulse = t
      const from = this.nodes[Math.floor(Math.random() * this.nodes.length)]
      this.pulses.push({from, start: t})
    }

    this.pulses = this.pulses.filter((p) => t - p.start < PULSE_TRAVEL_MS)
    this.hub.flash = Math.max(0, this.hub.flash - 0.04)

    for (const p of this.pulses) {
      if (t - p.start >= PULSE_TRAVEL_MS - 16) this.hub.flash = 1
    }
  },

  draw(t) {
    const {ctx, colors, nodes, hub} = this
    ctx.clearRect(0, 0, this.w, this.h)

    const edgeAlpha = this.dark ? 0.32 : 0.22
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

    ctx.globalAlpha = this.dark ? 0.8 : 0.6
    ctx.fillStyle = colors.node
    for (const n of nodes) {
      ctx.beginPath()
      ctx.arc(n.x, n.y, 1.6, 0, Math.PI * 2)
      ctx.fill()
    }

    // edges from every node to the hub, fainter — identity fan-in
    ctx.globalAlpha = this.dark ? 0.1 : 0.07
    ctx.strokeStyle = colors.hub
    for (const n of nodes) {
      ctx.beginPath()
      ctx.moveTo(n.x, n.y)
      ctx.lineTo(hub.x, hub.y)
      ctx.stroke()
    }

    // pulses traveling toward the hub
    for (const p of this.pulses) {
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

    // the hub itself, with a soft glow and arrival flash
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
}

export default GraphCanvas
