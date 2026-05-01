// Portal tooltip — moves the .cf-tip child to document.body on hover
// so it escapes any ancestor with overflow:hidden / overflow:auto and
// can render fully even when the parent table is in a horizontal-scroll
// container. Position is computed from the host element's bounding box.
export const Tooltip = {
  mounted() {
    this.tip = this.el.querySelector(":scope > .cf-tip")
    if (!this.tip) return

    this.parent = this.tip.parentElement
    this.onEnter = this.onEnter.bind(this)
    this.onLeave = this.onLeave.bind(this)

    this.el.addEventListener("mouseenter", this.onEnter)
    this.el.addEventListener("mouseleave", this.onLeave)
  },
  destroyed() {
    if (!this.tip) return
    this.el.removeEventListener("mouseenter", this.onEnter)
    this.el.removeEventListener("mouseleave", this.onLeave)
    if (this.tip.parentElement === document.body) {
      document.body.removeChild(this.tip)
    }
  },
  onEnter() {
    if (!this.tip) return

    document.body.appendChild(this.tip)
    const rect = this.el.getBoundingClientRect()

    // Position fixed under the header, right-aligned so most tip width
    // sits to the LEFT of the header (avoids running off-screen to the
    // right on the rightmost columns).
    this.tip.style.position = "fixed"
    this.tip.style.top = `${rect.bottom + 4}px`

    const tipWidth = this.tip.offsetWidth || 280
    let left = rect.right - tipWidth
    if (left < 8) left = 8
    if (left + tipWidth > window.innerWidth - 8) {
      left = window.innerWidth - tipWidth - 8
    }
    this.tip.style.left = `${left}px`
    this.tip.style.right = "auto"
    this.tip.style.maxHeight = `${window.innerHeight - rect.bottom - 16}px`
    this.tip.style.overflowY = "auto"

    requestAnimationFrame(() => {
      this.tip.style.opacity = "1"
      this.tip.style.visibility = "visible"
    })
  },
  onLeave() {
    if (!this.tip) return
    this.tip.style.opacity = "0"
    this.tip.style.visibility = "hidden"

    setTimeout(() => {
      if (this.tip && this.tip.parentElement === document.body && this.parent) {
        this.parent.appendChild(this.tip)
        // Reset inline positioning so the next hover starts clean.
        this.tip.style.position = ""
        this.tip.style.top = ""
        this.tip.style.left = ""
        this.tip.style.right = ""
        this.tip.style.maxHeight = ""
        this.tip.style.overflowY = ""
      }
    }, 180)
  },
}
