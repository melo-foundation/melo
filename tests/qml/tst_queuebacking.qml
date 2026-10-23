// ctest: melo stubs
import QtQuick
import QtTest
import "../../src/qml"

// The queue keeps its backing when it leaves the mini player's popup for a
// window of its own: what is painted under its rows, composited, is the same
// colour at the same opacity in both. Main.qml, built themes, flat roles only.
// Run: QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH=tests/qml/stubs qmltestrunner -input tests/qml/tst_queuebacking.qml
Item {
    width: 200; height: 100

    TestCase {
        name: "QueueBacking"
        when: windowShown

        property var main: null
        property var panel: null
        property var queueWin: null
        property var saved: ({})

        // built-in themes as ThemeStore folds them: the window's colour, the
        // scheme's master, the window's own opacity
        readonly property var themes: [
            { name: "Midnight Stars", window: "#0a1018", scale: 0.5, op: 0.5 },
            { name: "Dark Glass", window: "#0f0f0f", scale: 0.35, op: 0.35 },
            { name: "Dark", window: "#0f0f0f", scale: 1, op: 1 },
        ]
        // Transparency presets: every non-floating surface at the master
        readonly property var presets: [ { name: "Clear", scale: 0.75 }, { name: "Glass", scale: 0.5 } ]

        function typeOf(o) { return String(o).split("(")[0].split("_QML")[0].replace(/QQuick/, "") }
        function initTestCase() {
            saved = { p: Object.assign({}, Theme.p), ts: Object.assign({}, Theme.ts) }
            const c = Qt.createComponent("../../src/qml/Main.qml")
            verify(c.status === Component.Ready, c.errorString())
            main = c.createObject(null)
            verify(main !== null)
            const find = (it) => {
                if (!panel && typeOf(it) === "QueuePanel" && it.miniHost === true) panel = it
                for (const k of it.children) find(k)
            }
            find(main.contentItem)
            verify(panel !== null, "the popup's queue")
            for (const o of main.data)
                if (o && o.contentItem !== undefined && o.title === "melo-queue") queueWin = o
            verify(queueWin !== null, "the queue window")
        }
        function cleanupTestCase() {
            for (const k in Theme.p) if (saved.p[k] === undefined) delete Theme.p[k]
            for (const k in Theme.ts) if (saved.ts[k] === undefined) delete Theme.ts[k]
            Object.assign(Theme.p, saved.p); Object.assign(Theme.ts, saved.ts)
            Theme.pChanged(); Theme.tsChanged()
        }
        function wear(t, preset) {
            Theme.p.window = t.window
            const scale = preset ? preset.scale : t.scale
            const o = {}
            for (const k in Theme.opacityMap) o[k] = Theme.opacityMap[k]
            for (const r of Theme.surfaceRoles) if (Theme.floatingRoles.indexOf(r) < 0) delete o[r]
            o.window = preset ? preset.scale : t.op
            if (preset) for (const r of Theme.surfaceRoles) if (Theme.floatingRoles.indexOf(r) < 0) o[r] = preset.scale
            Theme.ts.opacity = o
            Theme.ts.opacityScale = scale
            Theme.pChanged(); Theme.tsChanged()
        }
        function popup() {
            main.miniPlayer = true
            main.miniVisWanted = false
            main.miniQueueShown = true
        }
        // one way only: putting it back asks WindowCtl, which a test has none of
        function detach() {
            main.detached = ({ queue: true, vis: false, video: false })
            queueWin.open = true
        }

        function ancestors(it) { const out = []; for (let a = it; a; a = a.parent) out.push(a); return out }
        // the item opacities from `it` up to (not into) the first of `stop`
        function chain(it, stop) {
            let v = 1
            for (let a = it; a && stop.indexOf(a) < 0; a = a.parent) v *= a.opacity
            return v
        }
        // Everything painted under the queue's rows, bottom first: each visible
        // surface or filled rectangle that covers the queue, in paint order, its
        // own ground among them. Opacity is relative to the queue's, so a fade
        // over the whole popup drops out.
        function backing() {
            const top = panel.Window.window.contentItem
            const r = panel.mapToItem(top, 0, 0, panel.width, panel.height)
            const up = ancestors(panel)
            const out = []
            let done = false
            const covers = (it) => {
                const q = it.mapToItem(top, 0, 0, it.width, it.height)
                return q.x <= r.x + 0.5 && q.y <= r.y + 0.5
                    && q.x + q.width >= r.x + r.width - 0.5 && q.y + q.height >= r.y + r.height - 0.5
            }
            const layer = (it, colour) => {
                const lca = ancestors(it).find(a => up.indexOf(a) >= 0)
                const rel = chain(it, [lca]) / chain(panel, [lca])
                out.push({ what: typeOf(it) + (it.role ? "[" + it.role + "]" : ""), r: colour.r, g: colour.g, b: colour.b, a: colour.a * rel })
            }
            const walk = (it) => {
                if (done || !it.visible || it.opacity <= 0) return
                const surface = typeOf(it) === "Surface"
                if (surface && covers(it)) layer(it, it.color)
                else if (!surface && typeOf(it) === "Rectangle" && typeOf(it.parent) !== "Surface"
                         && it.color.a > 0 && covers(it)) layer(it, it.color)
                const kids = Array.from(it.children).map((k, i) => ({ k, i }))
                kids.sort((x, y) => x.k.z - y.k.z || x.i - y.i)
                // the queue's own: only what it draws under its rows
                for (const e of kids) if (it !== panel || e.k.z < 0) walk(e.k)
                if (it === panel) done = true
            }
            walk(top)
            verify(done, "the queue is painted")
            verify(out.length > 0, "something backs the queue")
            return out
        }
        function composite(layers) {
            let r = 0, g = 0, b = 0, a = 0
            for (const l of layers) {
                const na = l.a + a * (1 - l.a)
                if (na > 0) {
                    r = (l.r * l.a + r * a * (1 - l.a)) / na
                    g = (l.g * l.a + g * a * (1 - l.a)) / na
                    b = (l.b * l.a + b * a * (1 - l.a)) / na
                }
                a = na
            }
            return { r, g, b, a }
        }
        function describe(ls) { return ls.map(l => l.what + " a=" + l.a.toFixed(3)).join(", ") }
        function rows() {
            const out = []
            for (const t of themes) {
                out.push({ name: t.name, theme: t, preset: null })
                for (const p of presets) out.push({ name: t.name + " with " + p.name, theme: t, preset: p })
            }
            return out
        }
        function test_detaching_keeps_the_backing() {
            const all = rows()
            popup()
            for (const row of all) { wear(row.theme, row.preset); wait(0); row.popup = backing() }
            detach()
            wait(0)
            verify(panel.Window.window === queueWin, "the queue moved into its window")
            const bad = []
            for (const row of all) {
                wear(row.theme, row.preset); wait(0)
                row.window = backing()
                const was = composite(row.popup), now = composite(row.window)
                if (Math.abs(was.a - now.a) > 0.005 || Math.abs(was.r - now.r) > 0.005
                        || Math.abs(was.g - now.g) > 0.005 || Math.abs(was.b - now.b) > 0.005)
                    bad.push(row.name + ": opacity " + was.a.toFixed(3) + " -> " + now.a.toFixed(3)
                             + " (popup " + describe(row.popup) + " / window " + describe(row.window) + ")")
            }
            if (bad.length) console.warn("backing changes on detach:\n" + bad.join("\n"))
            compare(bad.length, 0, bad.length + " of " + all.length + " themes change the queue's backing on detach")
        }
    }
}
