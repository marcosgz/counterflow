// TradingView free-embed widget hook.
//
// Renders a Binance Futures chart inside the host element. The element
// must carry data attributes:
//   data-symbol="BTCUSDT"
//   data-interval="5"          (TradingView interval — minutes or "D"/"W")
//
// Note: the free widget is a sealed iframe; we cannot overlay our own
// indicators on the price chart. Custom data lives in adjacent Chart.js
// panels (see ./chart_js.js).

export const TradingViewWidget = {
  mounted() {
    this.render()
  },
  updated() {
    // The element is keyed by symbol; phx-update prevents replacement.
    // No-op here unless the symbol attribute changes.
  },
  destroyed() {
    if (this.widget && this.widget.remove) {
      try { this.widget.remove() } catch (_e) { /* ignore */ }
    }
  },
  render() {
    if (typeof TradingView === "undefined") {
      this.el.innerHTML = "<div class='p-4 text-sm text-gray-500'>TradingView widget failed to load.</div>"
      return
    }
    const symbol = this.el.dataset.symbol || "BTCUSDT"
    const interval = this.el.dataset.interval || "5"
    const containerId = this.el.id

    this.widget = new TradingView.widget({
      autosize: true,
      symbol: `BINANCE:${symbol}.P`,    // .P suffix = USDT-M perpetual
      interval: interval,
      timezone: "Etc/UTC",
      theme: document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light",
      style: "1",                        // candles
      locale: "en",
      enable_publishing: false,
      allow_symbol_change: false,
      hide_side_toolbar: false,
      container_id: containerId,
    })
  },
}
