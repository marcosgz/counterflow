// Chart.js LiveView hook — renders one of several presets that mirror the
// custom TradingView widgets we want to recreate.
//
//   data-preset="oi"      — Open Interest, filled area, red-when-down/green-up
//   data-preset="exp"     — Exponential bars (cyan→amber→rose ramp by magnitude)
//   data-preset="rsi"     — RSI line with shaded overbought (>70) / oversold (<30) bands
//   data-preset="level"   — Smart Money Level vertical bars colored by 0..6 buckets
//   data-preset="line"    — generic line (LSR, etc.)
//   data-preset="bar"     — generic colored bar (funding rate)
//
// Pushes from server: { labels: [...], values: [...] } via
// "chart:update:<id>" events. Colors and axes are derived inside the hook
// so server payloads stay tiny.

const css = (varName) =>
  getComputedStyle(document.documentElement).getPropertyValue(varName).trim()

// Bucket → fill color map for Smart Money Level (mirrors the reference image:
// 0 grey, 1 cyan, 2 amber, 3 rose, 5 green, 6 magenta-pink emphasis).
const LEVEL_COLORS = [
  "rgba(140,140,150,0.55)",  // 0
  "rgba(34,211,238,0.85)",   // 1
  "rgba(245,158,11,0.85)",   // 2
  "rgba(244,63,94,0.85)",    // 3
  "rgba(34,211,238,0.85)",   // 4 (treated like 1)
  "rgba(34,197,94,0.95)",    // 5
  "rgba(217,70,239,1)",      // 6
]

const expColor = (v) => {
  const a = Math.min(Math.abs(v), 10) / 10
  if (a < 0.2) return "rgba(140,140,150,0.4)"
  if (a < 0.4) return `rgba(34,211,238,${0.5 + a * 0.4})`
  if (a < 0.7) return `rgba(245,158,11,${0.6 + a * 0.4})`
  return `rgba(34,197,94,${0.7 + a * 0.3})`
}

const oiColor = (current, prev) => {
  if (prev == null) return css("--ink-3") || "#999"
  return current >= prev ? (css("--long") || "#22d3ee") : (css("--short") || "#f43f5e")
}

const datasetFor = (preset, values, opts = {}) => {
  switch (preset) {
    case "oi": {
      // Single line + fill, color follows the latest tick direction.
      const last = values.at(-1) ?? 0
      const prev = values.at(-2) ?? last
      const color = oiColor(last, prev)
      return {
        type: "line",
        data: values,
        borderColor: color,
        backgroundColor: color.replace(/[\d.]+\)$/, "0.16)"),
        fill: true,
        tension: 0.25,
        borderWidth: 1.4,
        pointRadius: 0,
      }
    }
    case "exp": {
      return {
        type: "bar",
        data: values,
        backgroundColor: values.map((v) => expColor(v)),
        borderWidth: 0,
        barThickness: "flex",
        categoryPercentage: 1.0,
        barPercentage: 0.9,
      }
    }
    case "rsi": {
      const ink = css("--ink") || "#e8e9ed"
      return {
        type: "line",
        data: values,
        borderColor: ink,
        backgroundColor: "transparent",
        fill: false,
        tension: 0.25,
        borderWidth: 1.2,
        pointRadius: 0,
      }
    }
    case "level": {
      return {
        type: "bar",
        data: values,
        backgroundColor: values.map((v) => LEVEL_COLORS[Math.max(0, Math.min(6, Math.round(v)))]),
        borderWidth: 0,
        barThickness: "flex",
        categoryPercentage: 1.0,
        barPercentage: 0.9,
      }
    }
    case "bar": {
      return {
        type: "bar",
        data: values,
        backgroundColor: values.map((v) =>
          v >= 0 ? "rgba(34,211,238,0.75)" : "rgba(244,63,94,0.75)"
        ),
        borderWidth: 0,
      }
    }
    default: {
      const accent = opts.color || css("--ink") || "#e8e9ed"
      return {
        type: "line",
        data: values,
        borderColor: accent,
        backgroundColor: "transparent",
        fill: false,
        tension: 0.25,
        borderWidth: 1.2,
        pointRadius: 0,
      }
    }
  }
}

const baseOptions = (preset) => {
  const grid = css("--grid") || "rgba(255,255,255,0.04)"
  const ink3 = css("--ink-3") || "#6c7280"
  const opts = {
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    interaction: { mode: "nearest", intersect: false },
    plugins: { legend: { display: false }, tooltip: { enabled: true } },
    scales: {
      x: {
        grid: { display: false },
        ticks: { color: ink3, maxRotation: 0, autoSkip: true, maxTicksLimit: 6, font: { family: "JetBrains Mono", size: 9 } },
      },
      y: {
        position: "right",
        grid: { color: grid, drawBorder: false },
        ticks: { color: ink3, font: { family: "JetBrains Mono", size: 9 } },
      },
    },
    layout: { padding: { top: 4, right: 0, bottom: 0, left: 0 } },
  }

  if (preset === "rsi") {
    opts.scales.y.min = 0
    opts.scales.y.max = 100
    // Show 30/70 reference grid lines via tickValues hack — the visual band
    // is drawn manually on top after Chart.js renders (see drawRsiZones).
    opts.scales.y.ticks.stepSize = 25
  }

  return opts
}

// After-rendering hook to draw RSI bands underneath the line (like the
// Encryptos RSI reference image).
const drawRsiZones = {
  id: "rsiZones",
  beforeDatasetsDraw(chart) {
    if (chart.config.options._preset !== "rsi") return
    const { ctx, chartArea, scales } = chart
    const yTop = scales.y.getPixelForValue(70)
    const yBot = scales.y.getPixelForValue(30)
    ctx.save()
    ctx.fillStyle = "rgba(244,63,94,0.10)"
    ctx.fillRect(chartArea.left, chartArea.top, chartArea.right - chartArea.left, yTop - chartArea.top)
    ctx.fillStyle = "rgba(34,197,94,0.10)"
    ctx.fillRect(chartArea.left, yBot, chartArea.right - chartArea.left, chartArea.bottom - yBot)
    ctx.strokeStyle = "rgba(244,63,94,0.5)"
    ctx.beginPath()
    ctx.moveTo(chartArea.left, yTop)
    ctx.lineTo(chartArea.right, yTop)
    ctx.stroke()
    ctx.strokeStyle = "rgba(34,197,94,0.5)"
    ctx.beginPath()
    ctx.moveTo(chartArea.left, yBot)
    ctx.lineTo(chartArea.right, yBot)
    ctx.stroke()
    ctx.restore()
  },
}

export const ChartJSPanel = {
  mounted() {
    if (typeof Chart === "undefined") {
      console.warn("Chart.js not loaded; panel disabled")
      return
    }
    if (!Chart._cfPluginAdded) {
      Chart.register(drawRsiZones)
      Chart._cfPluginAdded = true
    }
    const ctx = this.el.getContext("2d")
    const preset = this.el.dataset.preset || "line"
    const options = baseOptions(preset)
    options._preset = preset

    this.chart = new Chart(ctx, {
      type: preset === "exp" || preset === "level" || preset === "bar" ? "bar" : "line",
      data: { labels: [], datasets: [] },
      options,
    })

    this.handleEvent(`chart:update:${this.el.id}`, (payload) => {
      const ds = datasetFor(preset, payload.values || [], payload.opts || {})
      this.chart.data.labels = payload.labels || []
      this.chart.data.datasets = [ds]
      this.chart.update("none")
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}
