// Live UTC clock in the status bar — pure client-side ticker.
export const StatusClock = {
  mounted() {
    this.tick = this.tick.bind(this)
    this.tick()
    this.interval = setInterval(this.tick, 1000)
  },
  destroyed() {
    clearInterval(this.interval)
  },
  tick() {
    const d = new Date()
    const pad = (n) => String(n).padStart(2, "0")
    this.el.textContent = `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())} UTC`
  },
}
