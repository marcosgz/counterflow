// Chart.js LiveView hook.
//
// The host element is a <canvas> with:
//   data-chart-type="line" | "bar"
//   data-initial-data='{"labels":[...], "datasets":[...]}'  (JSON)
//   data-y-format=""            optional formatter hint
//
// Receives `chart:update` events from the LiveView with new data and
// applies them in-place (no animation) for smooth streaming.

export const ChartJSPanel = {
  mounted() {
    if (typeof Chart === "undefined") {
      console.warn("Chart.js not loaded; panel disabled")
      return
    }
    const ctx = this.el.getContext("2d")
    const chartType = this.el.dataset.chartType || "line"
    let initial = { labels: [], datasets: [] }
    try {
      initial = JSON.parse(this.el.dataset.initialData || '{"labels":[],"datasets":[]}')
    } catch (_e) { /* keep default */ }

    this.chart = new Chart(ctx, {
      type: chartType,
      data: initial,
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: { mode: "nearest", intersect: false },
        plugins: { legend: { display: initial.datasets.length > 1 } },
        scales: {
          x: { ticks: { maxRotation: 0, autoSkip: true, maxTicksLimit: 8 } },
          y: { beginAtZero: false },
        },
      },
    })

    this.handleEvent(`chart:update:${this.el.id}`, (payload) => {
      this.chart.data.labels = payload.labels
      this.chart.data.datasets = payload.datasets
      this.chart.update("none")
    })
  },
  destroyed() {
    if (this.chart) this.chart.destroy()
  },
}
