// Theme toggle hook — binds clicks on each button inside the host
// element. Reads/writes localStorage.cf_theme and toggles the
// data-theme attribute on <html>. The inline script in root.html.heex
// already exposes window.cfSetTheme; we call that for consistency.
export const ThemeToggle = {
  mounted() {
    this.bind()
    this.sync()
  },
  updated() { this.sync() },
  bind() {
    this.handlers = []
    this.el.querySelectorAll("[data-cf-theme]").forEach((btn) => {
      const handler = (e) => {
        e.preventDefault()
        e.stopPropagation()
        const mode = btn.dataset.cfTheme
        if (typeof window.cfSetTheme === "function") {
          window.cfSetTheme(mode)
        } else {
          // Fallback if the inline script didn't run for any reason.
          if (mode === "auto") {
            localStorage.removeItem("cf_theme")
            document.documentElement.removeAttribute("data-theme")
          } else {
            localStorage.setItem("cf_theme", mode)
            document.documentElement.setAttribute("data-theme", mode)
          }
        }
        this.sync()
      }
      btn.addEventListener("click", handler)
      this.handlers.push([btn, handler])
    })
  },
  sync() {
    const current = localStorage.getItem("cf_theme") || "auto"
    this.el.querySelectorAll("[data-cf-theme]").forEach((b) => {
      b.classList.toggle("active", b.dataset.cfTheme === current)
    })
  },
  destroyed() {
    if (!this.handlers) return
    this.handlers.forEach(([btn, handler]) => btn.removeEventListener("click", handler))
    this.handlers = []
  },
}
