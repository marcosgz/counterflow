// Directional flash on text-content change. Compares the cell's text to
// its prior value; if the new value is numerically higher, applies a green
// pulse, lower → red. Pure client-side; the server doesn't need to track
// previous values.
//
// Used on the dense /panel table cells to surface live updates without
// the user having to re-read the whole grid.
export const CellFlash = {
  mounted() {
    this.prevText = this.el.textContent.trim()
  },
  updated() {
    const newText = this.el.textContent.trim()
    if (newText !== this.prevText && newText !== "" && this.prevText !== "") {
      const dir = directionalDelta(this.prevText, newText)
      if (dir !== 0) {
        const cls = dir > 0 ? "cf-flash-up" : "cf-flash-down"
        this.el.classList.remove("cf-flash-up", "cf-flash-down")
        // Force reflow so the animation restarts cleanly.
        // eslint-disable-next-line no-unused-expressions
        void this.el.offsetWidth
        this.el.classList.add(cls)
      }
    }
    this.prevText = newText
  },
}

const NUM_RE = /-?\d+(?:\.\d+)?/

// Returns +1 if newer is greater, -1 if smaller, 0 if equal/unparseable.
function directionalDelta(prev, current) {
  const mp = prev.match(NUM_RE)
  const mc = current.match(NUM_RE)
  if (!mp || !mc) return 0
  const np = parseFloat(mp[0])
  const nc = parseFloat(mc[0])
  if (isNaN(np) || isNaN(nc)) return 0
  if (nc === np) return 0
  return nc > np ? 1 : -1
}
