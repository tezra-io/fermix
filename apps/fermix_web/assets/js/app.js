// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/fermix_web"
import topbar from "../vendor/topbar"

// Reveals an "Unsaved changes" badge on the first edit within a setup pane and
// clears it on submit. Switching panes remounts the hook (the active_tab is in
// the element id), so the hint resets per pane. The badge lives in a
// phx-update="ignore" island so phx-change re-renders don't reset it mid-edit.
const UnsavedHint = {
  mounted() {
    this.badge = this.el.querySelector("[data-unsaved-badge]")
    const toggle = on => this.badge && this.badge.classList.toggle("hidden", !on)
    this.markDirty = () => toggle(true)
    this.markClean = () => toggle(false)
    this.el.addEventListener("input", this.markDirty)
    this.el.addEventListener("change", this.markDirty)
    this.el.addEventListener("submit", this.markClean, true)
    this.markClean()
  },
  destroyed() {
    this.el.removeEventListener("input", this.markDirty)
    this.el.removeEventListener("change", this.markDirty)
    this.el.removeEventListener("submit", this.markClean, true)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, UnsavedHint},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#2b5cff"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

let pendingAuthWindow = null

const openAuthPlaceholder = () => {
  pendingAuthWindow = window.open("about:blank", "_blank")
  if (!pendingAuthWindow) return

  pendingAuthWindow.opener = null
  pendingAuthWindow.document.title = "Opening sign-in"
  pendingAuthWindow.document.body.innerHTML = "<p>Opening sign-in...</p>"
}

const openAuthUrl = url => {
  if (!url) return

  const authWindow = pendingAuthWindow
  pendingAuthWindow = null

  if (authWindow && !authWindow.closed) {
    authWindow.location.replace(url)
    authWindow.focus()
    return
  }

  window.open(url, "_blank", "noopener,noreferrer")
}

window.addEventListener("click", event => {
  const trigger = event.target.closest("[data-auth-trigger='true'], [data-plugin-auth-trigger='true']")
  if (!trigger) return

  openAuthPlaceholder()
})

window.addEventListener("phx:plugin-auth-open", ({detail}) => {
  openAuthUrl(detail?.url)
})

window.addEventListener("phx:codex-auth-open", ({detail}) => {
  openAuthUrl(detail?.url)
})

window.addEventListener("phx:xai-auth-open", ({detail}) => {
  openAuthUrl(detail?.url)
})

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
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
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
