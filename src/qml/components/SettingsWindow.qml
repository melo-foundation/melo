import QtQuick
import QtQuick.Controls as QQC
import ".."
import "shortcuts.js" as SC
import "commands.js" as CMD
import "plugingrants.js" as PG
import "slots.js" as Slots
import "locales.js" as Locales
import "accounts.js" as Accounts

// Settings in a frameless window of its own, 480x520 by default:
// title bar, tab strip, full-width hoverable rows, glass background.
Window {
    id: win
    signal importPaths(var paths)   // Main imports them and opens the metadata editor
    // A rounded corner is at most half its rectangle's height, so the title bar
    // draws less than the window radius when it is short; the ground and the
    // border above it follow what it draws, or the bar pokes past their curve
    readonly property real topCornerRadius: framed && !Theme.borderTitle ? Theme.windowRadius
        : Math.min(Theme.windowRadius, (headShared ? titleBar.height + tabsBar.height : titleBar.height) / 2)
    // the window shape being edited: the theme's own, or none
    readonly property var shapeSpec: Theme.windowShape || ({})
    readonly property string shapeKind: "corners" in shapeSpec ? "corners" : "path" in shapeSpec ? "path"
                                      : "image" in shapeSpec ? "image" : ""
    function shapeWith(key, value) {
        const o = JSON.parse(JSON.stringify(shapeSpec))
        o[key] = value
        ThemeBackend.setThemeSetting("windowShape", o)
    }
    function setCorner(i, key, value) {
        const cs = JSON.parse(JSON.stringify(shapeSpec.corners || []))
        while (cs.length < 4) cs.push({ style: "round", size: Theme.windowRadius })
        cs[i][key] = value
        shapeWith("corners", cs)
    }
    function setShapeKind(kind) {
        const r = Theme.windowRadius, b = Theme.windowRadiusBottom
        ThemeBackend.setThemeSetting("windowShape",
            kind === "corners" ? { corners: [{ style: "round", size: r }, { style: "round", size: r },
                                             { style: "round", size: b }, { style: "round", size: b }] }
          : kind === "path" ? { path: "M0 0 H120 V60 H0 Z", box: [120, 60], slice: [10, 10, 10, 10] }
          : kind === "image" ? { image: "", slice: [0, 0, 0, 0], scale: 1 }
          : ({}))
    }
    // the frame's bands being edited: the theme's own list, or none
    readonly property var bandList: {
        const bs = Theme.ts.windowFrame && typeof Theme.ts.windowFrame === "object"
                   ? Theme.ts.windowFrame.bands : null
        const out = []
        // The colour is an entry, not a string: a band can be a fill as any
        // palette colour can, and reading it as text would throw the fill away
        if (bs) for (let i = 0; i < bs.length; ++i)
            out.push({ width: Number(bs[i].width) || 0,
                       colour: bs[i].colour !== undefined ? bs[i].colour : "",
                       role: String(bs[i].role || "") })
        return out
    }
    function setBands(list) {
        ThemeBackend.setThemeSetting("windowFrame", list.length ? ({ bands: list }) : ({}))
    }
    function setBand(i, key, value) {
        const l = bandList
        if (i >= l.length) return
        l[i][key] = value
        if (key === "colour") l[i].role = ""
        if (key === "role" && value !== "") l[i].colour = ""
        setBands(l)
    }
    // the roles a band can follow, and what they are called in this section
    readonly property var bandRoles: [{ k: "windowBorder", l: "Border" },
                                      { k: "windowBorderOuter", l: "Outer line" },
                                      { k: "windowBorderInner", l: "Inner line" }]
    function bandRoleLabel(k) {
        for (const r of win.bandRoles) if (r.k === k) return r.l
        return k
    }
    function addBand() {
        const l = bandList
        l.push({ width: 2, colour: Theme.role("windowBorder").colour.toString(), role: "" })
        setBands(l)
    }
    // numbers typed with spaces or commas, exactly n of them
    function shapeNums(text, n) {
        const a = String(text).trim().split(/[\s,]+/).map(Number)
        return a.length === n && a.every(x => isFinite(x)) ? a : null
    }
    // What the window's shape cuts from each edge (WindowShapeItem.intrusion):
    // the title bar's ends, and the body under it. A cut deeper than the frame
    // would otherwise take the words and the controls drawn there.
    property real cutTitleL: 0
    property real cutTitleR: 0
    property real cutBodyL: 0
    property real cutBodyR: 0
    // a surface fills a shaped window and the shape cuts it; what sits on it
    // starts inside the deeper of the frame and the cut
    readonly property bool shaped: shapeLoader.item && shapeLoader.item.active && shapeLoader.item.hasShape
    function readCuts() {
        const sh = shapeLoader.item
        const titleH = Theme.titleBarH
        cutTitleL = shaped ? Math.max(frL, sh.intrusion("left", 0, titleH)) : frL
        cutTitleR = shaped ? Math.max(frR, sh.intrusion("right", 0, titleH)) : frR
        cutBodyL = shaped ? Math.max(frL, sh.intrusion("left", titleH, height)) : frL
        cutBodyR = shaped ? Math.max(frR, sh.intrusion("right", titleH, height)) : frR
    }
    onShapedChanged: readCuts()
    readonly property bool frameOff: (win.visibility === Window.Maximized || win.visibility === Window.FullScreen)
                                     && !Theme.borderMaximized
    readonly property real frL: frameOff ? 0 : Theme.borderLeft
    readonly property real frT: frameOff ? 0 : Theme.borderTop
    readonly property real frR: frameOff ? 0 : Theme.borderRight
    readonly property real frB: frameOff ? 0 : Theme.borderBottom
    readonly property bool framed: frL > 0 || frT > 0 || frR > 0 || frB > 0
    readonly property real titleGap: Theme.borderTitle ? frT : 0
    readonly property real titleCap: framed && !Theme.borderTitle ? Math.max(0, Theme.windowRadius - Math.max(frL, frT)) : Theme.windowRadius

    // One surface across the title and the tabs when the theme draws the main
    // window's header as one; this window has no search row, so the pairings
    // with it leave each row its own
    readonly property bool headShared: Theme.headerGroup === "all"
    // the locale table is owned by the sidecar so the picker and the validator
    // can never disagree; fetched once per open
    property var localeList: []
    property var regionList: []
    function fetchLocales() {
        if (!visible || localeList.length > 0) return
        sidecar.rpc("settings/locales", {}, (r) => {
            if (!r.ok || !r.result) return
            if (r.result.locales) win.localeList = r.result.locales
            if (r.result.regions) win.regionList = r.result.regions
        })
    }
    width: 480
    height: 520
    // The tab strip cannot elide, wrap or scroll, so the window's minimum width
    // follows it; a fixed 480 cut "Plugins" off at a large font scale.
    minimumWidth: Math.max(400, tabsRow.implicitWidth + 20)
    // Qt grows a window to meet a rising minimum but never shrinks it back
    // when the minimum falls, so raising the font size would widen this
    // window permanently. If the window was only that wide BECAUSE of the minimum,
    // it follows the minimum back down; a width you chose yourself is kept.
    property int heldAt: 0
    onMinimumWidthChanged: {
        if (win.width <= win.heldAt) win.width = win.minimumWidth
        win.heldAt = win.minimumWidth
    }
    Component.onCompleted: win.heldAt = win.minimumWidth
    minimumHeight: 380
    visible: false
    color: "transparent"
    title: "melo settings"
    flags: Qt.Window | Qt.FramelessWindowHint

    property string tab: "general"
    // main window area vs the 1920x1080 reference — the count row shows the
    // drawn element count under count-density scaling
    property real mainAreaRatio: 1

    // local mirrors, loaded on open (writes go straight through)
    property bool cfOnSkip: false
    property int scrollSpeed: 3
    property real tileGrowth: 4
    // At a fractional scale a logical size is a fractional device size, Qt stretches
    // the scene onto the rounded buffer and edges shimmer. Snapping to the grain where
    // size * dpr is whole fixes that, resizing in steps (2px at 150%).
    property bool gridSnap: false
    readonly property int gridStep: {
        if (typeof WindowCtl === "undefined") return 1
        const d = (WindowCtl.dprGeneration, WindowCtl.dprOf(win))
        if (!(d > 0)) return 1
        const n = Math.round(d * 120); let a = n, b = 120
        while (b) { const t = a % b; a = b; b = t }
        return 120 / a
    }
    property var shortcuts: SC.merged(null)
    property var gestures: ({})
    property string recordingAction: ""
    onRecordingActionChanged: {
        if (typeof CommandMap !== "undefined" && CommandMap)
            CommandMap.setCapturing(recordingAction.length > 0)
    }

    // The accounts are AccountStore's, shared with the title bar and the
    // wizard, so a sign-in shows in all three at once.
    readonly property var cookieProfiles: AccountStore.profiles
    readonly property var accountEntries: AccountStore.entries
    // the services are auto-tag's; with it off they are hidden, not rewritten
    readonly property bool autoTagOn: Settings.metadataAutoEnrich === "new"
    // plugins (derived from the sidecar via RPC, not a settings key)
    property var pluginList: []

    // ---- slots: which QML draws each of melo's named places ----
    // Depends on `SlotMap.generation` because occupant() and offersFor() are methods
    // and nothing else here moves when a bind or offer changes.
    readonly property var slotRows: {
        if (typeof SlotMap === "undefined" || !SlotMap) return []
        const dep = SlotMap.generation
        const names = ({})
        for (let i = 0; i < pluginList.length; i++)
            names[pluginList[i].id] = pluginList[i].name
        const ids = SlotMap.slotIds()
        const entries = []
        for (let j = 0; j < ids.length; j++)
            entries.push({ id: ids[j], bound: SlotMap.occupant(ids[j]),
                           offers: SlotMap.offersFor(ids[j]) })
        return Slots.rows(entries, names, SlotMap.hiddenId)
    }
    // ---- plugin bar buttons: which of them the user has taken out ----
    //
    // Every button, hidden or not — hiding one has to leave it here or there
    // would be no way to put it back.
    readonly property var barButtonRows: {
        if (typeof BarButtons === "undefined" || !BarButtons) return []
        const dep = BarButtons.generation
        const names = ({})
        for (let i = 0; i < pluginList.length; i++)
            names[pluginList[i].id] = pluginList[i].name
        const out = []
        const all = BarButtons.all()
        for (let j = 0; j < all.length; j++) {
            const b = all[j]
            // Two labels, because this row is read in two places. On the
            // plugin's own page the plugin's name is the page title, so
            // repeating it in every row is noise; in a list of every plugin's
            // buttons it is the only thing telling them apart.
            out.push({ pluginId: b.pluginId, id: b.id, bar: b.bar,
                       label: (names[b.pluginId] || b.pluginId) + " — " + b.label,
                       ownLabel: b.label + " button in the "
                                 + (b.bar === "title" ? "title bar" : "player bar"),
                       shown: !BarButtons.isHidden(b.pluginId, b.id) })
        }
        return out
    }
    function showBarButton(pluginId, id, on) {
        BarButtons.setHidden(pluginId, id, !on)
        Settings.uiSet("hiddenBarButtons", BarButtons.hiddenKeys())
    }

    // One object under the Qt-owned `ui` bag, beside `gestures`, and restored
    // by Main.qml at startup — the shell has to draw the user's slots before
    // this window has ever been opened.
    function bindSlot(id, occupant) {
        SlotMap.setOccupant(id, occupant)
        const out = ({})
        const ids = SlotMap.slotIds()
        for (let i = 0; i < ids.length; i++) {
            const held = SlotMap.occupant(ids[i])
            if (held !== "") out[ids[i]] = held
        }
        Settings.uiSet("slots", out)
    }
    Connections {
        target: sidecar
        function onPluginsChanged(plugins) { win.pluginList = plugins }
    }
    // rescan (not just list) so a folder dropped in since last time is picked
    // up automatically — no manual Rescan button, no restart
    function refreshPlugins() {
        if (visible && tab === "plugins") sidecar.rescanPlugins()
    }
    onVisibleChanged: {
        pluginSettingsFor = ""
        if (!visible) recordingAction = ""
        refreshPlugins()
        fetchLocales()      // the locale list is fetched on open
    }
    onTabChanged: {
        pluginSettingsFor = ""
        refreshPlugins()
        if (tab !== "shortcuts") recordingAction = ""
    }

    // ---- per-plugin settings page (empty id = the plugin LIST is showing) ----
    // which appearance sections are open, persisted across visits

    property var apprOpen: ({})
    function secOpen(kind) { return win.apprOpen[kind] === true }
    function pickPalette(key, entry, allowBlend) {
        colorPicker.open(entry !== undefined ? entry : Theme[key].toString(), ({
            commit: (c) => ThemeBackend.setPaletteColor(key, c),
            preview: (c) => ThemeBackend.previewPaletteColor(key, c),
            blend: allowBlend !== false, adaptive: true }))
    }
    // the theme's swatches, re-read when they change (no appearance key
    // moves, so Theme.p does not fire for them)
    property int themeSwatchRev: 0
    Connections {
        target: ThemeBackend
        function onThemeSwatchesChanged() { win.themeSwatchRev++ }
    }
    readonly property var themeSwatchList: {
        const d1 = ThemeBackend.palette, d2 = win.themeSwatchRev
        const v = ThemeBackend.themeSwatches(), out = []
        if (Theme.isList(v)) for (let i = 0; i < v.length; ++i) if (v[i] && v[i].id !== undefined) out.push(v[i])
        return out
    }
    // What a section owns of the theme. Two sections share the palette: the
    // inks are TEXT & SYMBOLS, every other role and the opacities are COLOURS.
    function sectionDirty(kind) {
        if (kind === "palette") return ThemeBackend.rolesDirty(Theme.inkRoles, false)
        if (kind === "surfaces") return ThemeBackend.rolesDirty(Theme.inkRoles, true) || ThemeBackend.partDirty("surfaces")
        return ThemeBackend.partDirty(kind)
    }
    function resetSection(kind) {
        if (kind === "palette") { ThemeBackend.discardRoles(Theme.inkRoles, false); return }
        if (kind === "surfaces") { ThemeBackend.discardRoles(Theme.inkRoles, true); ThemeBackend.discardPart("surfaces"); return }
        ThemeBackend.discardPart(kind)
    }
    function newSwatchId() { return "s" + Date.now().toString(36) + Math.floor(Math.random() * 4096).toString(36) }
    function dropThemeSwatch(id) {
        ThemeBackend.setThemeSwatches(win.themeSwatchList.filter(s => String(s.id) !== String(id)))
    }
    // A theme swatch's right-click: the other theme swatches' values, then
    // the recents — choosing one writes it into this swatch, and so into
    // every role using it
    function swatchMenu(sw, from) {
        const rows = []
        for (const o of win.themeSwatchList) if (String(o.id) !== String(sw.id))
            rows.push({ label: String(o.name), entry: o.entry, act: () => Theme.setThemeSwatch(sw.id, sw.name, o.entry) })
        const rs = colorPicker.recentList()
        for (let i = 0; i < rs.length; ++i) {
            const e = rs[i]
            rows.push({ label: win.swatchName(e) || Theme.entryLabel(e), entry: e, rule: i === 0 && rows.length > 0,
                        act: () => Theme.setThemeSwatch(sw.id, sw.name, e) })
        }
        if (rows.length === 0) return
        const p = from.mapToItem(null, 0, from.height + 2)
        winMenu.openAt(win, p.x, p.y, rows)
    }
    // A role swatch's right-click: the theme's own value, the theme's swatches
    // (a role taking one USES it), then the last five entries made or applied,
    // by value
    function recentMenu(key, from) {
        const rows = []
        // the theme's own value first: choosing it drops the edit
        const te = ThemeBackend.themeEntry(key)
        if (te !== undefined && te !== null)
            rows.push({ label: "Theme", entry: te, act: () => ThemeBackend.discardRoles([key], false) })
        for (const sw of win.themeSwatchList)
            rows.push({ label: String(sw.name), entry: sw.entry,
                        act: () => ThemeBackend.setPaletteColor(key, Theme.stamped(sw.entry, sw.id)) })
        const rs = colorPicker.recentList()
        for (let i = 0; i < rs.length; ++i) {
            const e = rs[i]
            rows.push({ label: win.swatchName(e) || Theme.entryLabel(e), entry: e, rule: i === 0 && rows.length > 0,
                        act: () => { colorPicker.remember(e); ThemeBackend.setPaletteColor(key, e) } })
        }
        if (rows.length === 0) return
        if (te !== undefined && te !== null && rows.length > 1) rows[1].rule = true
        const p = from ? from.mapToItem(null, 0, from.height + 2) : Qt.point(win.width - 220, 120)
        winMenu.openAt(win, p.x, p.y, rows)
    }
    // the name an entry was saved under, if it was: the theme swatch it
    // uses, else a swatch on either shelf holding the same value
    function swatchName(e) {
        const code = Theme.entryToCode(e)
        const from = (e !== null && typeof e === "object" && e.from !== undefined) ? String(e.from) : ""
        const lists = [ThemeBackend.themeSwatches(), Settings.uiGet("swatches", [])]
        for (const l of lists) if (Theme.isList(l))
            for (let i = 0; i < l.length; ++i)
                if (l[i] && (String(l[i].id) === from || Theme.entryToCode(l[i].entry) === code)) return String(l[i].name)
        return ""
    }
    // the theme swatch a role uses, by its stamp: what the row says beside
    // the swatch, so a role on a swatch is told apart from one that merely
    // matches it
    function usesSwatch(e) {
        const from = (e !== null && typeof e === "object" && e.from !== undefined) ? String(e.from) : ""
        if (from.length === 0) return ""
        const l = win.themeSwatchList
        for (let i = 0; i < l.length; ++i) if (String(l[i].id) === from) return String(l[i].name)
        return ""
    }
    // test hook: the picker itself, for a probe that drives it
    function pickerHook() { return colorPicker }
    // test hook: the Colours chip's click, for a key
    function editChip(key) {
        const cur = Theme.entryOf(key)
        colorPicker.open(cur !== undefined ? cur : Theme[key].toString(), ({
            commit: (c) => ThemeBackend.setPaletteColor(key, c),
            preview: (c) => ThemeBackend.previewPaletteColor(key, c), adaptive: true }))
    }
    // ---- simple mode: the theme as its colours ------------------------------
    // Stored in the profile, not the theme; full is the default. Read on open like
    // every ui key here: uiGet is a method, so a binding never hears the write.
    property bool simpleAppearance: false
    readonly property var colourGroupList: Theme.colourGroups(ThemeBackend.palette)
    // One write for the whole group. recolour hands back a whole palette; only
    // the roles the group touches changed, and only those are written.
    function recolourGroup(g, c) {
        const out = Theme.recolour(ThemeBackend.palette, g, c)
        const patch = ({})
        for (let i = 0; i < g.places.length; ++i) patch[g.places[i].role] = out[g.places[i].role]
        ThemeBackend.setPalette(patch)
    }
    // KNOWN LIMIT: one previewPaletteColor per role, so a drag emits themeChanged
    // once per role in the group rather than once. Fine for the handful a
    // group spans; if a wide group ever drags roughly, ThemeStore wants a
    // previewPalette(map) that resolves them all and emits once.
    function previewGroup(g, c) {
        const out = Theme.recolour(ThemeBackend.palette, g, c), done = ({})
        for (let i = 0; i < g.places.length; ++i) {
            const r = g.places[i].role
            if (done[r] === undefined) { done[r] = 1; ThemeBackend.previewPaletteColor(r, out[r]) }
        }
    }
    // A group becomes a theme swatch. Only a role whose whole entry is this colour
    // can be stamped: the swatch rewrites the whole entry when it changes, which would
    // discard a stack, fill or blend. A colour inside a stack, palette stop or halo
    // keeps the colour and takes no stamp.
    function swatchFromGroup(g) {
        const id = win.newSwatchId()
        const entry = String(Theme.colourFromHex(g.colour))
        const patch = ({})
        for (let i = 0; i < g.places.length; ++i) {
            const pl = g.places[i], e = Theme.entryOf(pl.role)
            if (pl.path.length === 0) { patch[pl.role] = Theme.stamped(entry, id); continue }
            if (pl.path.length !== 1 || pl.path[0] !== "colour" || e === null || typeof e !== "object") continue
            let bare = true
            for (const k in e) if (k !== "colour" && k !== "from") bare = false
            if (bare) patch[pl.role] = Theme.stamped(entry, id)
        }
        Theme.setThemeSwatch(id, g.colour, entry)
        if (Object.keys(patch).length > 0) ThemeBackend.setPalette(patch)
    }
    // test hook: a colour group's row, by index
    function editGroup(i, hex) {
        const g = win.colourGroupList[i]
        if (g !== undefined) win.recolourGroup(g, String(Theme.colourFromHex(hex)))
    }
    // test hook: the theme dropdown, at its real length
    function openThemeMenu() {
        winMenu.openAt(win, win.width - 220, 120,
                       ThemeBackend.themes.map(t => ({ label: t.name, act: () => {} })))
    }
    function toggleSec(kind) {
        const o = {}
        for (const k in win.apprOpen) o[k] = win.apprOpen[k]
        o[kind] = !(o[kind] === true)
        win.apprOpen = o
        Settings.uiSet("apprSections", o)
    }

    property string pluginSettingsFor: ""
    property var pluginSettingsValues: ({})
    // key -> filenames present in the plugin's data dir, for `file` fields
    property var pluginSettingsFiles: ({})
    readonly property var pluginSettingsSchema: {
        for (const p of win.pluginList)
            if (p.id === win.pluginSettingsFor) return p.settings || []
        return []
    }
    readonly property var pluginSettingsPlugin: {
        for (const p of win.pluginList)
            if (p.id === win.pluginSettingsFor) return p
        return null
    }
    // Turned off, or uninstalled, while its page is open: the page goes back
    // to the list rather than staying up over a plugin that is not there.
    onPluginSettingsPluginChanged: {
        if (win.pluginSettingsFor.length > 0
            && (!win.pluginSettingsPlugin || !win.pluginSettingsPlugin.enabled))
            win.pluginSettingsFor = ""
    }
    // `state` and `error` disagree after a plugin is toggled off while broken:
    // the sidecar sets state "stopped" and leaves the old error in place. Read
    // the STATE, and show the message only where it is still the live one.
    function pluginStatus(p) {
        if (p.state === "error")   return "⚠ " + (p.error || "invalid")
        if (p.state === "crashed") return "⚠ " + (p.error || "crashed")
        return ""
    }
    function openPluginSettings(id) {
        pluginSettingsFor = id
        pluginSettingsValues = ({})
        pluginSettingsFiles = ({})
        fetchPluginSettings()
    }
    function fetchPluginSettings() {
        const id = win.pluginSettingsFor
        if (!id) return
        sidecar.rpc("plugins/getSettings", { id: id }, (r) => {
            if (win.pluginSettingsFor !== id) return    // page changed under the reply
            win.pluginSettingsValues = (r.ok && r.result && r.result.values) || ({})
        })
        fetchPluginSettingFileLists()
    }
    // Driven off the SCHEMA, not off opening the page: the plugin's own
    // openPluginSettings() can land here before any plugin list has arrived, so
    // the schema is still empty and this loop has nothing to walk. It re-runs
    // when the list lands, which is the only moment the `file` rows exist.
    function fetchPluginSettingFileLists() {
        if (!win.pluginSettingsFor) return
        for (const f of win.pluginSettingsSchema)
            if (f.type === "file") fetchPluginSettingFiles(f.key)
    }
    onPluginSettingsSchemaChanged: fetchPluginSettingFileLists()
    function fetchPluginSettingFiles(key) {
        const id = win.pluginSettingsFor
        sidecar.rpc("plugins/settingFiles", { id: id, key: key }, (r) => {
            if (win.pluginSettingsFor !== id) return
            const m = {}
            for (const k in win.pluginSettingsFiles) m[k] = win.pluginSettingsFiles[k]
            m[key] = (r.ok && r.result && r.result.files) || []
            win.pluginSettingsFiles = m
        })
    }
    // The sidecar validates against the manifest schema and returns the whole
    // authoritative bag, so an out-of-schema write corrects itself here.
    function setPluginSetting(key, value) {
        const id = win.pluginSettingsFor
        sidecar.rpc("plugins/setSetting", { id: id, key: key, value: value }, (r) => {
            // The running plugin is told separately: the sidecar broadcasts nothing on a
            // write, and the bridge fetches only at construction, sidecar-ready and plugin
            // restart. Not gated on the page being open; the write landed either way.
            if (r.ok && PluginUi && PluginUi.has(id)) PluginUi.refreshSettings(id)
            if (win.pluginSettingsFor !== id) return
            if (r.ok && r.result && r.result.values) win.pluginSettingsValues = r.result.values
        })
    }
    function pluginFileOptions(field) {
        const files = win.pluginSettingsFiles[field.key] || []
        return files.map(f => ({ value: f, label: f }))
    }
    function pluginNetworkDesc(p) {
        const n = (p.permissions && p.permissions.network) || []
        if (!n.length) return ""
        return "\n" + n.join(", ")
    }
    // Rows, ⚠ copy, checked state and the patch itself are in plugingrants.js —
    // pure functions of one plugin's PluginInfo, tested in tst_plugingrants.qml.
    // This is the only writer of grants in QML.
    function applyPluginGrant(p, kind, on, action) {
        sidecar.setPluginGrants(p.id, PG.patch(p, kind, on, action))
    }
    property string importBrowser: "firefox"
    property string importResult: ""
    property bool importing: false
    property string enrichResult: ""
    property bool enriching: false
    readonly property var browserOptions: [
        { value: "firefox", label: "Firefox" },
        { value: "chrome", label: "Chrome" },
        { value: "chromium", label: "Chromium" },
        { value: "brave", label: "Brave" },
        { value: "edge", label: "Edge" } ]
    // after a profile is made, renamed or deleted: the lists, not a re-read of
    // every browser's store
    function refreshProfiles() { AccountStore.refresh(false) }

    function open() {
        cfOnSkip = Settings.uiGet("crossfadeOnSkip", false) === true
        simpleAppearance = String(Settings.uiGet("appearanceMode", "full")) === "simple"
        scrollSpeed = Number(Settings.uiGet("scrollSpeed", 3))
        tileGrowth = Number(Settings.uiGet("tileGrowth", 4))
        gridSnap = Settings.uiGet("gridSnap", false) === true
        shortcuts = SC.merged(Settings.uiGet("shortcuts", null))
        const rawS = Settings.uiGet("apprSections", null)
        if (rawS) win.apprOpen = rawS
        const rawG = Settings.uiGet("gestures", null)
        const g = {}
        if (rawG) for (const k in rawG) if (rawG[k]) g[k] = rawG[k]
        gestures = g
        importResult = ""
        enrichResult = ""
        AccountStore.refresh(true)   // opening settings re-reads every browser's login
        applyGlass()
        visible = true
        requestActivate()
    }
    function setShortcut(action, seq) {
        const m = {}
        for (const k in shortcuts) m[k] = shortcuts[k]
        // Plugin full ids are unknown to SC.DEFAULTS; still persist them.
        // Empty plugin keys are deleted (not stored as "") so merge does not
        // treat a hole as a saved binding.
        if (seq || (SC.DEFAULTS[action] !== undefined))
            m[action] = seq
        else
            delete m[action]
        shortcuts = m
        Settings.uiSet("shortcuts", m)   // Main re-merges on Settings.changed
        recordingAction = ""
    }
    function bindGesture(gestureId, commandId) {
        gestures = CMD.applyGesture(gestures, gestureId, commandId)
        Settings.uiSet("gestures", gestures)
    }
    function clearGestures(commandId) {
        gestures = CMD.clearOccupants(gestures, commandId)
        Settings.uiSet("gestures", gestures)
    }
    function defaultGestures(commandId) {
        gestures = CMD.defaultGestures(gestures, commandId)
        Settings.uiSet("gestures", gestures)
    }
    // melo's OWN commands. A plugin's belong to the plugin, on its own page,
    // and a plugin that is switched off has none to bind.
    readonly property var shortcutRows: CMD.commandRows(SC.ORDER, SC.LABELS, null)
    readonly property var pluginShortcutRows:
        CMD.commandRows([], {}, win.pluginSettingsPlugin ? [win.pluginSettingsPlugin] : [])
    function applyGlass() {
        const on = Theme.glassBlur !== "off" && Theme.translucent("window")
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(win, on)
        WindowCtl.setBackgroundContrast(win, on, Theme.glassContrast, Theme.glassSaturation)
    }
    // Every family the system can draw, the default first. Sorted, and
    // de-duplicated: fontconfig reports the same family once per foundry.
    function fontOptions() {
        const seen = {}
        const out = [{ value: "", label: "Red Hat Display", sub: "default" }]
        const fams = Qt.fontFamilies()
        for (let i = 0; i < fams.length; i++) {
            const f = fams[i]
            if (!f || seen[f] || f.charAt(0) === ".") continue
            seen[f] = true
            out.push({ value: f, label: f, sub: "" })
        }
        return out
    }

    // a slot with an unsaved arrangement says so: its document is what the
    // bar draws, whatever layout the slot names
    function slotNote(slot) {
        // settings as well as the generation: the overrides arrive with the
        // settings, after this window is built, and a note bound only to the
        // generation would stay empty until something else wrote a theme
        const dep = win.presetGen, dep2 = ThemeBackend.settings
        return ThemeBackend.hasLayoutOverride(slot) ? "  ·  Custom" : ""
    }
    // the layouts a slot can name: the built-ins, then what was saved
    property int presetGen: 0
    readonly property var barKinds: {
        const dep = win.presetGen
        return ThemeBackend.presets("layout").map(p => ({ value: p.id, label: p.name }))
    }
    Connections { target: ThemeBackend; function onThemesChanged() { win.presetGen++ } }
    readonly property var backKinds: [ { value: "surface", label: "Surface" }, { value: "none", label: "None" },
                                       { value: "floating", label: "Floating" } ]
    readonly property var tabStyles: [ { value: "filled", label: "Filled" },
                                       { value: "pill", label: "Pill" },
                                       { value: "underline", label: "Underline" },
                                       { value: "segment", label: "Segment" },
                                       { value: "button", label: "Button" } ]
    readonly property var iconButtonStyles: [ { value: "bare", label: "Bare" },
                                              { value: "button", label: "Button" } ]
    readonly property var knobShapes: [ { value: "round", label: "Round" },
                                        { value: "square", label: "Square" } ]
    readonly property var skeletonStyles: [ { value: "shimmer", label: "Shimmer" },
                                            { value: "pulse", label: "Pulse" },
                                            { value: "still", label: "Still" } ]
    readonly property var scrollbarStyles: [ { value: "bar", label: "Bar" },
                                             { value: "slider", label: "Slider" } ]
    readonly property var gripStyles: [ { value: "none", label: "None" },
                                        { value: "lines", label: "Lines" } ]
    // "" is the volume following the slider's shape
    readonly property var volumeShapes: [ { value: "", label: "Slider" },
                                          { value: "round", label: "Round" },
                                          { value: "square", label: "Square" } ]
    readonly property var pressStyles: [ { value: "none", label: "None" },
                                         { value: "face", label: "Face" },
                                         { value: "sink", label: "Sink" } ]
    // a theme picked but not yet applied: the strip of its parts shows
    property string staged: ""
    property var stagedParts: []
    readonly property string stagedName: {
        for (const t of ThemeBackend.themes) if (t.id === staged) return t.name
        return staged
    }
    readonly property var partLabels: ({ palette: "Colours", window: "Window", type: "Font", surfaces: "Surfaces",
                                         transparency: "Transparency", behaviour: "Behaviour", size: "Size",
                                         background: "Background", controls: "Controls", player: "Player",
                                         insets: "Insets", glyphs: "Glyphs", layout: "Layout" })
    readonly property var insetLabels: ({ page: "Page", pageHeader: "Page header", header: "Search bar", tabs: "Tabs", title: "Title bar", player: "Player bar",
                                          panel: "Panel", row: "List row", input: "Text input", menu: "Menu", dialog: "Dialog",
                                          toast: "Toast", tooltip: "Tooltip", cardArt: "Card art", cardText: "Card text",
                                          settings: "Settings rows", settingsHover: "Settings hover", tool: "Tool windows", scrollbar: "Scrollbar" })
    // one side of one structure's inset, the other three kept as they are
    function setInset(name, side, v) {
        const all = Object.assign({}, Theme.insetMap), cur = {}
        for (const s of Theme.insetSides) cur[s] = Theme.insetOf(name, s)
        // Negative is a bleed: art over the card's edge, a label past the
        // row's, a bar wider than the surface under it. The theme's own
        // numbers are not clamped either.
        cur[side] = Math.max(-64, Math.min(64, Math.round(Number(v) || 0)))
        all[name] = cur
        ThemeBackend.setThemeSetting("insets", all)
    }
    function stage(id) {
        // the same theme again is a reset: the file applied over the edits
        if (id === ThemeBackend.activeId) { staged = ""; if (ThemeBackend.dirty) ThemeBackend.discard(); return }
        staged = id; stagedParts = ThemeBackend.partsOfTheme(id)
    }
    // Save as theme, part by part: own values, a pointer to the theme it is
    // unchanged from, or left out. The default is own where changed, a
    // pointer where unchanged from a theme that has it, off where the theme
    // lacked it and nothing changed.
    property bool saving: false
    property string saveName: ""
    property var saveChoice: ({})
    function startSave() {
        const has = ThemeBackend.partsOfTheme(ThemeBackend.activeId)
        const c = {}
        for (const p of ThemeBackend.themeParts())
            c[p] = (has.indexOf(p) >= 0 || p === "palette") ? "own" : "off"
        // the base name, without a stack of Copy and Custom on it
        const base = ThemeBackend.activeName.replace(/( Copy| Custom)+$/, "")
        saveChoice = c; saveName = base + (ThemeBackend.dirty ? " Custom" : " Copy"); saving = true
    }
    // Arrange happens on the main window's bar; this window sits over it,
    // so it steps aside and comes back on Done
    property bool asideForArrange: false
    function arrange(slot) { Theme.arrangeSlot = slot; Theme.arranging = true; asideForArrange = true; win.visible = false }
    Connections {
        target: Theme
        function onArrangingChanged() { if (!Theme.arranging && win.asideForArrange) { win.asideForArrange = false; win.visible = true } }
    }
    // Glyph import: which row asked, and what the importer said about it.
    // The message stays under that row's name until it is tried again.
    property string glyphFor: ""
    property var glyphError: ({})
    function setGlyph(name, entry) {
        const o = JSON.parse(Theme.glyphKey)
        if (entry === undefined) delete o[name]; else o[name] = entry
        ThemeBackend.setThemeSetting("glyphs", o)
    }
    // the colours that are not a surface: chips above the rows
    readonly property var accentRows: [
        { key: "accent", label: "Accent" },
        { key: "accentHover", label: "Accent hover" },
        { key: "scrubber", label: "Scrubber" },
        { key: "graph", label: "Graph" },
        { key: "tabLine", label: "Tab underline" },
        { key: "border", label: "Border" },
        { key: "borderStrong", label: "Border hover" },
        { key: "danger", label: "Danger" },
    ]
    // one row per role, in the order they are drawn
    readonly property var surfaceRows: [
        { key: "window", label: "Window" },
        { key: "page", label: "Page" },
        { key: "title", label: "Title bar" },
        { key: "chrome", label: "Header" },
        { key: "player", label: "Player bar" },
        { key: "card", label: "Card" },
        { key: "cardSelected", label: "Card selected" },
        { key: "button", label: "Button" },
        { key: "input", label: "Text input" },
        { key: "hover", label: "Hover" },
        { key: "buttonHover", label: "Button hover" },
        { key: "buttonPress", label: "Button press" },
        { key: "closeFace", label: "Close face" },
        { key: "closeFaceHover", label: "Close face hover" },
        { key: "closeFacePress", label: "Close face press" },
        { key: "titleButton", label: "Title bar button" },
        { key: "titleButtonHover", label: "Title bar button hover" },
        { key: "titleButtonPress", label: "Title bar button press" },
        { key: "titleButtonActive", label: "Title bar button on" },
        { key: "titleButtonBorder", label: "Title bar button edge" },
        { key: "titleButtonBorderHover", label: "Title bar button edge hover" },
        { key: "selected", label: "Selected" },
        { key: "buttonActive", label: "Button active" },
        { key: "sliderTrack", label: "Slider track" },
        { key: "sliderFill", label: "Slider fill" },
        { key: "sliderKnob", label: "Slider knob" },
        { key: "volumeTrack", label: "Volume track" },
        { key: "volumeFill", label: "Volume fill" },
        { key: "volumeKnob", label: "Volume knob" },
        { key: "toggleOff", label: "Toggle off" },
        { key: "toggleOn", label: "Toggle on" },
        { key: "toggleKnob", label: "Toggle knob" },
        { key: "scrollbar", label: "Scrollbar" },
        { key: "scrollbarTrack", label: "Scrollbar track" },
        { key: "scrollbarThumb", label: "Scrollbar thumb" },
        { key: "scrubberTrack", label: "Scrubber track" },
        { key: "scrubberKnob", label: "Scrubber knob" },
        { key: "panel", label: "Panel" },
        { key: "panelHeader", label: "Panel header" },
        { key: "dialog", label: "Dialog" },
        { key: "menu", label: "Menu" },
        { key: "toast", label: "Toast" },
        { key: "tooltip", label: "Tooltip" },
        { key: "skeleton", label: "Loading bars" },
    ]
    // And the theme's own: a theme may add a role melo does not know — a
    // deck's screen, a small transport's face — and it is recoloured here
    // too; its key is its name.
    readonly property var ownRows: {
        const seen = {}
        for (const r of surfaceRows) seen[r.key] = 1
        for (const r of accentRows) seen[r.key] = 1
        for (const r of bandRoles) seen[r.k] = 1       // the window's, in WINDOW
        for (const r of Theme.inkRoles) seen[r] = 1
        const out = []
        for (const k of Object.keys(ThemeBackend.palette || {}))
            // an invented ink says so in its name and belongs with the text
            if (seen[k] === undefined && !/Ink$/.test(k)) out.push({ key: k, label: k })
        return out.sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0)
    }
    function ts(key, fallback) {
        const v = ThemeBackend.settings[key]
        return v !== undefined ? v : fallback
    }
    // Every surface role draws through Surface.qml, so every one takes a
    // blend; text over artwork is the one ink that does. tst_themekeys checks
    // this against Theme.surfaceRoles.
    readonly property var blendableKeys: Theme.surfaceRoles.concat(Theme.inkRoles)
    // `opacity` is one object holding every role's number; a slider writes the whole
    // map back with its role changed.
    // An ink's effect is a sub-object of its entry: a change merges into the stored
    // effect and writes the entry back; `preview` moves only the resolved palette.
    function effectOfKey(key) { return Theme.inkRole(key).effect }
    function effectColourOfKey(key) { return Theme.inkEffectColour(key) }
    function setInkEffect(key, patch, preview) {
        const cur = Theme.entryOf(key)   // its own, or the entry it follows
        const entry = (cur !== null && typeof cur === "object")
                      ? Object.assign({}, cur)
                      : ({ colour: cur !== undefined ? String(cur) : Theme[key].toString() })
        const eff = Object.assign({}, effectOfKey(key))
        for (const k in patch) eff[k] = patch[k]
        entry.effect = eff
        if (preview === true) { ThemeBackend.previewPaletteColor(key, entry); return }
        ThemeBackend.setPaletteColor(key, entry)
    }
    function setRoleOpacity(role, v) {
        const o = {}
        const cur = Theme.opacityMap
        for (const k in cur) o[k] = cur[k]
        o[role] = v
        ThemeBackend.setThemeSetting("opacity", o)
    }

    // theme background config {type, gradient, src, opacity, blur, options{}}
    function bgCfg() { return ts("background", { type: "none" }) || { type: "none" } }
    function bg(key, fallback) {
        const c = bgCfg()
        return c[key] !== undefined ? c[key] : fallback
    }
    // Which of the two directions BackgroundLayer will render. It
    // treats ~45-135deg as horizontal and everything else as vertical, so the
    // settings row has to read the string the same way the renderer does or
    // the control shows one thing and the window draws another.
    function gradientIsHorizontal(css) {
        const m = String(css).match(/(-?[\d.]+)deg/)
        if (!m) return false
        const d = Number(m[1])
        return d > 45 && d < 135
    }

    function bgOpt(key, fallback) {
        const o = bgCfg().options || {}
        return o[key] !== undefined ? o[key] : fallback
    }
    function setBg(patch) {   // shallow-merge into the background config
        const c = bgCfg(); const next = {}
        for (const k in c) next[k] = c[k]
        for (const k in patch) next[k] = patch[k]
        ThemeBackend.setThemeSetting("background", next)
    }
    function setBgOpt(patch) {
        const c = bgCfg(); const o = c.options || {}; const no = {}
        for (const k in o) no[k] = o[k]
        for (const k in patch) no[k] = patch[k]
        setBg({ options: no })
    }

    Surface {   // translucent base over the whole window
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
        // the top corners as the title bar draws them: no more than half its height
        topLeftRadius: win.topCornerRadius; topRightRadius: win.topCornerRadius
        bottomLeftRadius: Theme.windowRadiusBottom; bottomRightRadius: Theme.windowRadiusBottom
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: tabsBar.y + tabsBar.height
        anchors.leftMargin: win.shaped ? 0 : win.frL
        anchors.rightMargin: win.shaped ? 0 : win.frR
        anchors.bottomMargin: win.shaped ? 0 : win.frB
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Math.max(0, Theme.windowRadiusBottom - Math.max(win.frL, win.frB))
        bottomRightRadius: Math.max(0, Theme.windowRadiusBottom - Math.max(win.frR, win.frB))
        visible: Theme.hasPage
    }
    Loader {   // the window's shape (WindowMask)
        id: shapeLoader
        parent: win.contentItem
        anchors.fill: parent
        z: 10000000
        active: typeof WindowCtl !== "undefined"
        source: "WindowMask.qml"
        onLoaded: {
            item.shapeApplied.connect(win.readCuts)
            item.spec = Qt.binding(() => Theme.panelShapeFor(win.topCornerRadius, Theme.windowRadiusBottom))
            // a maximised window is the screen's shape
            item.active = Qt.binding(() => item.spec !== null && win.visibility !== Window.Maximized
                                           && win.visibility !== Window.FullScreen)
        }
    }
    WindowBorder {   // the window frame and border; with the title in it, round the title too
        anchors.fill: parent
        borderLeft: win.frL; borderTop: win.frT; borderRight: win.frR; borderBottom: win.frB
        titleHeight: Theme.borderTitle && !win.frameOff ? titleBar.height : 0
        shape: shapeLoader.item && shapeLoader.item.active ? shapeLoader.item : null
        titleRim: win.frameOff ? 0 : Theme.borderTitleRim
        titleFade: Theme.borderTitleFade
        radiusTL: win.topCornerRadius
        radiusTR: win.topCornerRadius
        radiusBL: Theme.windowRadiusBottom; radiusBR: Theme.windowRadiusBottom
        visible: win.framed || (!win.frameOff && Theme.frameDepth > 0)
        z: 1000
    }

    Surface {   // the title and the tabs' shared surface
        x: titleBar.x; y: titleBar.y
        width: titleBar.width
        height: tabsBar.y + tabsBar.height - titleBar.y
        visible: win.headShared
        role: "title"
        topLeftRadius: win.topCornerRadius; topRightRadius: win.topCornerRadius
    }
    // ---------- title bar ----------
    Surface {
        id: titleBar
        x: Theme.borderTitle ? 0 : win.frL
        y: Theme.borderTitle ? 0 : win.frT
        width: parent.width - (Theme.borderTitle ? 0 : win.frL + win.frR)
        height: Theme.titleBarH
        role: win.headShared ? "" : "title"      // a title bar, as the main window's is
        topLeftRadius: Math.min(win.titleCap, height / 2)
        topRightRadius: Math.min(win.titleCap, height / 2)
        MouseArea { anchors.fill: parent; onPressed: win.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left
            anchors.leftMargin: Theme.inset("title", "left") + win.cutTitleL - (Theme.borderTitle ? 0 : win.frL)
            text: "Settings"
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(Theme.titleFontSize); family: Theme.fontFamily; weight: Theme.titleWeight }
        }
        Item {
            anchors.right: parent.right
            anchors.rightMargin: Theme.inset("title", "right") + win.cutTitleR - (Theme.borderTitle ? 0 : win.frR)
            // on whole pixels, as the main window's buttons are
            y: Math.round((parent.height - height + Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2)
            width: Theme.titleButtons === "button" ? Theme.titleBtn : Theme.ctl(26)
            height: Theme.titleButtons === "button" && Number(Theme.ts.titleButtonSize) > 0 ? Theme.titleBtn : Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(13)
                ink: closeMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: closeMa.containsMouse; pressed: closeMa.pressed
                frameWidth: Theme.titleBtn; frameHeight: Theme.titleBtnH }
            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: win.visible = false }
        }
    }

    // ---------- tabs ----------
    Surface {
        id: tabsBar
        anchors.top: titleBar.bottom
        anchors.topMargin: win.titleGap
        x: win.shaped ? 0 : win.frL
        width: parent.width - (win.shaped ? 0 : win.frL + win.frR)
        // the tabs plus the inset above and below, as the main window's strip
        readonly property real tabH: Theme.pageTabs === "underline" ? 34 : (Theme.pageTabs === "button" ? Theme.btnH : Theme.tabHeight)
        // the segment track sits a pad outside the tabs: room for it, as the
        // main window's strip makes (AppTabBar)
        readonly property real trackPad: Theme.pageTabs === "segment" ? Theme.tabTrackPad : 0
        height: tabH + 2 * trackPad + Theme.inset("tabs", "top") + Theme.inset("tabs", "bottom")
        role: win.headShared ? "" : "chrome"     // a tab strip, as the main window's header is
        SegmentTrack { strip: tabsRow; style: Theme.pageTabs }
        Row {
            id: tabsRow
            anchors.left: parent.left
            anchors.leftMargin: Theme.inset("tabs", "left") + parent.trackPad   // the same strip as the main window's
            anchors.top: parent.top
            anchors.topMargin: Theme.inset("tabs", "top") + parent.trackPad
            height: parent.tabH
            // underlined tabs share the strip and segments share a track;
            // blocks and pills stand apart, as the header's do
            spacing: (Theme.pageTabs === "underline" || Theme.pageTabs === "segment") ? 0 : Theme.gap(Theme.tabGap)
            component STab: SelectTab {
                property string key
                active: win.tab === key
                hover: stMa.containsMouse; pressed: stMa.pressed
                style: Theme.pageTabs
                fontSize: 13
                width: implicitWidth
                height: line ? parent.height : (button ? Theme.btnH : Theme.tabHeight)
                anchors.verticalCenter: parent.verticalCenter
                MouseArea { id: stMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: win.tab = parent.key }
            }
            STab { key: "general"; label: "General" }
            STab { key: "personalization"; label: "Personalization" }
            STab { key: "appearance"; label: "Appearance" }
            STab { key: "shortcuts"; label: "Shortcuts" }
            STab { key: "plugins"; label: "Plugins" }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width
                    height: 1; color: Theme.border }
    }

    // ---------- content: full-width rows ----------
    Flickable {
        objectName: "settingsFlick"
        id: settingsFlick
        QQC.ScrollBar.vertical: MScrollBar {}
        anchors.top: tabsBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: win.shaped ? 0 : win.frL
        anchors.rightMargin: win.shaped ? 0 : win.frR
        anchors.bottomMargin: win.shaped ? 0 : win.frB
        anchors.topMargin: Theme.gap(4)
        contentHeight: col.implicitHeight + 8
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        WheelScroll { target: settingsFlick }

        Column {
            id: col
            // the rows start inside what the shape cuts; the page they sit on
            // runs to the frame
            x: win.shaped ? win.cutBodyL : 0
            width: settingsFlick.width - Theme.scrollGutter - (win.shaped ? win.cutBodyL + win.cutBodyR : 0)

            // a setting row: full width, the theme's settings insets, hover overlay
            component SRow: Surface {
                property string name
                property string desc
                // width kept clear on the right for the control(s). Rows with
                // more than one control raise it, or the label runs underneath.
                property real reserve: 176
                default property alias control: slot.data
                width: col.width
                height: Math.max(nameCol.implicitHeight, slot.childrenRect.height) + Theme.inset("settings", "top") + Theme.inset("settings", "bottom")
                role: ""
                // The hover fill is its own surface, inset from the row's edge
                // by the theme; the label and the control stay where they are
                Surface {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.inset("settingsHover", "left"); anchors.rightMargin: Theme.inset("settingsHover", "right")
                    anchors.topMargin: Theme.inset("settingsHover", "top"); anchors.bottomMargin: Theme.inset("settingsHover", "bottom")
                    radius: (anchors.leftMargin + anchors.topMargin + anchors.rightMargin + anchors.bottomMargin) > 0 ? Theme.radiusMd : 0
                    role: srMa.containsMouse ? "hover" : ""
                }
                MouseArea { id: srMa; anchors.fill: parent; hoverEnabled: true
                            acceptedButtons: Qt.NoButton }
                Column {
                    id: nameCol
                    anchors.verticalCenter: parent.verticalCenter
                    // An uneven pair leans the row's content: the row grows by
                    // top + bottom, and centring alone would ignore the difference
                    anchors.verticalCenterOffset: (Theme.inset("settings", "top") - Theme.inset("settings", "bottom")) / 2
                    anchors.left: parent.left; anchors.leftMargin: Theme.inset("settings", "left")
                    width: parent.width - anchors.leftMargin - parent.reserve
                    spacing: Theme.gap(2)
                    // width + elide, or the label paints at its IMPLICIT width
                    // and runs straight through the controls — `reserve` sizes
                    // this Column, and a Text that sets no width ignores it.
                    InkText { width: parent.width
                           elide: Text.ElideRight
                           text: parent.parent.name; ink: "text"
                           font { pixelSize: Theme.fs(13); family: Theme.fontFamily } }
                    InkText { width: parent.width; text: parent.parent.desc; ink: "textFaint"
                           visible: text.length > 0
                           wrapMode: Text.Wrap
                           font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                }
                Item {
                    id: slot
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.inset("settings", "right")
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: nameCol.anchors.verticalCenterOffset
                    width: Theme.sp(150); height: Theme.sp(24)
                }
            }

            // A palette role's swatch, opening the picker on it: left click
            // edits it, right click offers the recent entries
            component RoleChip: Surface {
                id: rc
                property string roleName
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: Theme.ctl(40); height: Theme.btnH; radius: Theme.radiusMd
                role: Theme.faceOf("button", rcMa.containsMouse, rcMa.pressed)
                borderWidth: 1
                borderRole: rcMa.containsMouse ? "borderStrong" : "border"
                EntryChip {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: Theme.pressShift(rcMa.pressed)
                    anchors.verticalCenterOffset: Theme.pressShift(rcMa.pressed)
                    width: Theme.ctl(24); height: Theme.ctl(14)
                    entry: Theme.entryOf(rc.roleName)
                    fallback: Theme.roleColour(rc.roleName)
                }
                MouseArea {
                    id: rcMa; anchors.fill: parent; hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (m) => m.button === Qt.RightButton ? win.recentMenu(rc.roleName, rcMa) : colorPicker.open(
                        Theme.entryOf(rc.roleName) !== undefined
                            ? Theme.entryOf(rc.roleName) : Theme.roleColour(rc.roleName).toString(),
                        ({ commit: (c) => ThemeBackend.setPaletteColor(rc.roleName, c),
                           preview: (c) => ThemeBackend.previewPaletteColor(rc.roleName, c),
                           adaptive: true }))
                }
            }
            // A frame band's colour, edited the way every other colour here is.
            // The band's own entry, or the palette role it follows — right
            // click chooses which, left click opens the picker on it.
            component BandChip: Surface {
                id: bc
                property int index: 0
                property var band: ({})
                readonly property string roleName: String(bc.band.role || "")
                readonly property var entry: bc.roleName.length ? Theme.entryOf(bc.roleName) : bc.band.colour
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.ctl(40); height: Theme.btnH; radius: Theme.radiusMd
                role: Theme.faceOf("button", bcMa.containsMouse, bcMa.pressed)
                borderWidth: 1
                borderRole: bcMa.containsMouse ? "borderStrong" : "border"
                EntryChip {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: Theme.pressShift(bcMa.pressed)
                    anchors.verticalCenterOffset: Theme.pressShift(bcMa.pressed)
                    width: Theme.ctl(24); height: Theme.ctl(14)
                    entry: bc.entry
                    fallback: bc.roleName.length ? Theme.roleColour(bc.roleName) : Qt.color("#00000000")
                }
                MouseArea {
                    id: bcMa; anchors.fill: parent; hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (m) => m.button === Qt.RightButton ? bc.follows() : bc.edit()
                }
                function edit() {
                    if (bc.roleName.length) {
                        colorPicker.open(bc.entry !== undefined ? bc.entry : Theme.roleColour(bc.roleName).toString(),
                            ({ commit: (c) => ThemeBackend.setPaletteColor(bc.roleName, c),
                               preview: (c) => ThemeBackend.previewPaletteColor(bc.roleName, c),
                               adaptive: true }))
                        return
                    }
                    const e = bc.band.colour
                    colorPicker.open(e !== undefined && e !== "" ? e : Theme.roleColour("windowBorder").toString(),
                        ({ commit: (c) => win.setBand(bc.index, "colour", c), adaptive: true }))
                }
                function follows() {
                    const p = bc.mapToItem(null, 0, bc.height + 2)
                    const rows = [{ label: "Own colour", act: () => win.setBand(bc.index, "colour",
                                                                               Theme.roleColour("windowBorder").toString()) }]
                    for (const r of win.bandRoles)
                        rows.push({ label: r.l, entry: Theme.entryOf(r.k), act: () => win.setBand(bc.index, "role", r.k) })
                    winMenu.openAt(win, p.x, p.y, rows, bc)
                }
            }
            component SToggle: MToggle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
            }

            // MSlider anchored to the row, holding the settings list still
            // while it takes focus
            component SSlider: MSlider {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                holdFlick: settingsFlick
            }

            component SSelect: SelectHead {
                id: ss
                property var options: []
                property string value
                property string note: ""   // after the value: a slot's unsaved arrangement
                signal picked(string v)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                function labelFor(v) {
                    for (const o of options) if (o.value === v) return o.label
                    return v
                }
                label: labelFor(value) + note
                menu: winMenu
                onClicked: {
                    const p = ss.mapToItem(null, 0, ss.height + 2)
                    winMenu.openAt(win, p.x, p.y, ss.options.map(o =>
                        ({ label: o.label, act: () => ss.picked(o.value) })), ss)
                }
            }

            // A section header, not a container: a `default property alias` also redirects
            // the component's own children into the target, putting the header and fold
            // button inside the section. The rows are a plain Column beside this.
            component SectionHead: Item {
                property string title
                property string kind
                property bool presets: true   // a section that is not a part has no preset to name
                readonly property bool open: win.secOpen(kind)
                width: col.width
                height: Theme.sp(34)

                InkText {
                    x: Theme.inset("settings", "left")
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\u25b8"
                    rotation: parent.open ? 90 : 0
                    Behavior on rotation { NumberAnimation { duration: 120 } }
                    ink: "textFaint"
                    font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
                }
                InkText {
                    anchors.verticalCenter: parent.verticalCenter
                    x: Theme.inset("settings", "left") + 16
                    text: parent.title
                    ink: "textFaint"
                    font { pixelSize: Theme.fs(10); weight: Theme.weightBold
                           family: Theme.fontFamily; letterSpacing: 0.5 }
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.rightMargin: parent.presets ? Theme.sp(170) : 0
                    onClicked: win.toggleSec(parent.kind)
                }
                SSelect {
                    visible: parent.presets
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.inset("settings", "right")
                    anchors.verticalCenter: parent.verticalCenter
                    // Theme, a preset (matched by value), or Custom when it is neither; picking
                    // Theme restores it. `settings` and `palette` are the notifying properties that
                    // make it re-check.
                    value: {
                        const d1 = ThemeBackend.settings, d2 = ThemeBackend.palette
                        const d3 = ThemeBackend.themes
                        if (!win.sectionDirty(parent.kind)) return "Theme"
                        return ThemeBackend.matchingPreset(parent.kind) || "Custom"
                    }
                    options: {
                        const dep = ThemeBackend.themes   // notifies on save/import/delete
                        return [{ value: "Theme", label: "Theme" }].concat(
                            ThemeBackend.presets(parent.kind).map(p => ({ value: p.id, label: p.name })))
                    }
                    onPicked: (v) => v === "Theme" ? win.resetSection(parent.kind) : ThemeBackend.applyPreset(parent.kind, v)
                }
            }

            // Save / Export / Import for a section, shown only while it is open
            component SectionTools: Item {
                property string title
                property string kind
                width: col.width
                height: Theme.sp(34)
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.gap(16)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(6)
                    SBtn { label: "Save preset"
                           onClicked: winPrompt.promptDialog(
                               "Preset name", parent.parent.title,
                               (n) => { if (n) ThemeBackend.savePreset(parent.parent.kind, n) }) }
                    SBtn { label: "Export"
                           onClicked: Portal.saveFile("preset-export:" + parent.parent.kind,
                               "Export preset", parent.parent.title + ".json",
                               "Preset", ["*.json"]) }
                    SBtn { label: "Import"
                           onClicked: Portal.openFile("preset-import", "Import preset",
                               "Preset", ["*.json"], false) }
                }
            }

            // One shortcut row, used by the Shortcuts tab for melo's commands
            // and by a plugin's own page for that plugin's, with the same key
            // button, gesture picker and reset.
            component ShortcutRow: SRow {
                id: srow
                property var row: ({})
                readonly property string actionId: srow.row.id
                readonly property string seq: win.shortcuts[actionId] || ""
                readonly property string defSeq: SC.DEFAULTS[actionId] !== undefined
                                                 ? SC.DEFAULTS[actionId] : ""
                readonly property bool recording: win.recordingAction === actionId
                readonly property string gestureText: {
                    const g = win.gestures
                    for (let i = 0; i < CMD.GESTURES.length; i++) {
                        const gid = CMD.GESTURES[i]
                        const occ = (g && g[gid]) || CMD.GESTURE_DEFAULTS[gid]
                        if (occ === actionId) return CMD.LABELS[gid]
                    }
                    return "—"
                }
                name: srow.row.label
                desc: ""
                reserve: 300
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.gap(6)
                    SBtn {
                        visible: srow.seq !== srow.defSeq
                        label: "Reset"
                        onClicked: win.setShortcut(srow.actionId, srow.defSeq)
                    }
                    SelectHead {   // gesture picker (catalog ids + clear/default)
                        id: gMa
                        label: srow.gestureText
                        menu: winMenu
                        onClicked: {
                            const acts = []
                            for (let i = 0; i < CMD.GESTURES.length; i++) {
                                const gid = CMD.GESTURES[i]
                                acts.push({
                                    label: CMD.LABELS[gid],
                                    act: () => win.bindGesture(gid, srow.actionId)
                                })
                            }
                            // None unbinds every gesture this command holds;
                            // Default hands them back to their default owners
                            acts.push({ label: "None",
                                        act: () => win.clearGestures(srow.actionId) })
                            if (CMD.hasGestureDefault(srow.actionId))
                                acts.push({ label: "Default",
                                            act: () => win.defaultGestures(srow.actionId) })
                            const p = gMa.mapToItem(null, 0, gMa.height + 2)
                            winMenu.openAt(win, p.x, p.y, acts, gMa)
                        }
                    }
                    Rectangle {   // key button
                        width: skText.implicitWidth + 20; height: Theme.btnH
                        radius: Theme.radiusMd
                        color: srow.recording
                               ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15)
                               : Theme[Theme.faceOf("button", skMa.containsMouse, skMa.pressed)]
                        border.color: srow.recording ? Theme.accent
                                    : (skMa.containsMouse ? Theme.borderStrong : Theme.border)
                        InkText { id: skText; anchors.centerIn: parent
                               anchors.horizontalCenterOffset: Theme.pressShift(skMa.pressed)
                               anchors.verticalCenterOffset: Theme.pressShift(skMa.pressed)
                               text: srow.recording ? "Press a key..."
                                                    : SC.format(srow.seq)
                               ink: srow.recording ? "highlight" : "text"
                               font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                        MouseArea {
                            id: skMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: {
                                win.recordingAction = srow.recording ? "" : srow.actionId
                                if (win.recordingAction.length)
                                    keyCatcher.forceActiveFocus()
                            }
                        }
                    }
                }
            }

            // the one that undoes something wears the danger ink
            component SBtn: PushButton {}

            // The effect of one ink, as one row: what it is, and the words
            // with it on them; the editing happens in EffectPicker.
            component EffectRows: SRow {
                id: erows
                property string key
                readonly property var eff: win.effectOfKey(key)
                readonly property bool effOn: eff.kind !== "off"
                name: "Effect"
                desc: effOn ? eff.kind + " · " + Number(eff.size).toFixed(1) + " · " + Math.round(eff.opacity * 100) + "%" : ""
                reserve: 120
                Surface {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: Theme.ctl(96); height: Theme.ctl(30)
                    radius: Theme.radiusMd
                    role: Theme.faceOf("button", epMa.containsMouse, epMa.pressed)
                    borderWidth: 1
                    borderRole: epMa.containsMouse ? "borderStrong" : "border"
                    Text {
                        id: epSample
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: Theme.pressShift(epMa.pressed)
                        anchors.verticalCenterOffset: Theme.pressShift(epMa.pressed)
                        text: erows.effOn ? "Aa" : "off"
                        color: erows.effOn ? Theme[erows.key] : Theme.textDim
                        font { pixelSize: Theme.fs(erows.effOn ? 16 : 11); family: Theme.fontFamily; weight: Theme.weightMedium }
                        Loader {
                            z: -1
                            active: erows.effOn
                            source: "TextHalo.qml"
                            onLoaded: {
                                item.label = epSample
                                item.inside = true
                                item.effect = Qt.binding(() => erows.eff)
                                item.colour = Qt.binding(() => win.effectColourOfKey(erows.key))
                            }
                        }
                    }
                    MouseArea {
                        id: epMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: effectPicker.openFor(erows.key,
                            (e) => win.setInkEffect(erows.key, e),
                            (e) => win.setInkEffect(erows.key, e, true),
                            (entry, cb, live) => colorPicker.open(entry, ({ commit: cb, preview: live, adaptive: true })))
                    }
                }
            }

            // A background colour, picked with the colour picker rather than
            // typed as hex.
            component SSwatch: Surface {
                property color value: "#000000"
                signal picked(color c)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.sp(150); height: Theme.sp(24)
                radius: Theme.radiusMd
                role: "input"
                borderWidth: 1
                borderRole: swMa.containsMouse ? "accent" : "border"
                Rectangle {
                    id: chip
                    anchors.left: parent.left; anchors.leftMargin: Theme.gap(5)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.sp(16); height: Theme.sp(16)
                    radius: Theme.radiusSm
                    color: parent.value
                    border.color: Theme.border
                }
                // The value, because a row shows its current value.
                InkText {
                    anchors.left: chip.right; anchors.leftMargin: Theme.gap(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(parent.value).toUpperCase()
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                MouseArea {
                    id: swMa; anchors.fill: parent; hoverEnabled: true
                    onClicked: colorPicker.open(parent.value, ({ commit: (c) => parent.picked(c) }))
                }
            }

            // Point at the part you want kept. The crop is two normalised
            // numbers, so the control is the picture and a click sets them.
            component SCropPick: Surface {
                id: cropPick
                property string src: ""
                property real px: 0.5
                property real py: 0.5
                signal picked(real x, real y)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.sp(180)
                // follow the picture's own shape, so the click maps straight
                // onto it with no letterboxing to correct for
                height: Math.round(width * (cropImg.sourceSize.width > 0
                        ? cropImg.sourceSize.height / cropImg.sourceSize.width : 0.5625))
                radius: Theme.radiusSm
                role: "button"
                borderRole: "border"
                clip: true
                Image {
                    id: cropImg
                    anchors.fill: parent
                    source: cropPick.src
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                }
                Rectangle {
                    x: Math.round(cropPick.px * cropPick.width) - width / 2
                    y: Math.round(cropPick.py * cropPick.height) - height / 2
                    width: Theme.ctl(14); height: Theme.ctl(14)
                    radius: Theme.pill(width / 2)
                    color: "transparent"
                    border.color: "#ffffff"; border.width: 2
                    Rectangle { anchors.centerIn: parent; width: 2; height: 2
                                color: "#ffffff" }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: (m) => cropPick.picked(
                        Math.max(0, Math.min(1, m.x / cropPick.width)),
                        Math.max(0, Math.min(1, m.y / cropPick.height)))
                }
            }

            // The list form: one chip per colour, click to change, right-click
            // to drop, + to add. The comma-separated string stays the storage
            // format; nobody has to read or write it.
            component SSwatchList: Item {
                id: swList
                property string csv: ""
                property int minCount: 2
                signal changed(string csv)
                readonly property var parts: csv.split(",").map((c) => c.trim()).filter((c) => c.length > 0)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.sp(150)
                height: Math.max(Theme.sp(24), swRow.height)

                function replaceAt(i, c) {
                    const a = parts.slice(); a[i] = String(c); changed(a.join(","))
                }
                function removeAt(i) {
                    const a = parts.slice(); a.splice(i, 1); changed(a.join(","))
                }
                function append(c) {
                    changed(parts.concat([String(c)]).join(","))
                }

                Flow {
                    id: swRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    spacing: Theme.gap(4)
                    layoutDirection: Qt.RightToLeft

                    // add
                    Surface {
                        width: Theme.sp(22); height: Theme.sp(22)
                        radius: Theme.radiusSm
                        role: Theme.faceOf("button", addMa.containsMouse, addMa.pressed)
                        borderWidth: 1
                        borderRole: addMa.containsMouse ? "borderStrong" : "border"
                        Icon { anchors.centerIn: parent; name: "plus"; size: Theme.glyph(11)
                               anchors.horizontalCenterOffset: Theme.pressShift(addMa.pressed)
                               anchors.verticalCenterOffset: Theme.pressShift(addMa.pressed)
                               ink: "textDim" }
                        MouseArea {
                            id: addMa; anchors.fill: parent; hoverEnabled: true
                            onClicked: colorPicker.open(
                                swList.parts.length ? swList.parts[swList.parts.length - 1] : "#4a9eff",
                                ({ commit: (c) => swList.append(c) }))
                        }
                    }
                    Repeater {
                        model: swList.parts
                        Rectangle {
                            required property int index
                            required property string modelData
                            width: Theme.sp(22); height: Theme.sp(22)
                            radius: Theme.radiusSm
                            color: modelData
                            border.color: chipMa.containsMouse ? Theme.accent : Theme.border
                            border.width: chipMa.containsMouse ? 2 : 1
                            MouseArea {
                                id: chipMa; anchors.fill: parent; hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (m) => {
                                    if (m.button === Qt.RightButton) {
                                        // the last two are the gradient; a
                                        // background with one colour is not one
                                        if (swList.parts.length > swList.minCount)
                                            swList.removeAt(index)
                                    } else {
                                        colorPicker.open(modelData, ({ commit: (c) => swList.replaceAt(index, c) }))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // A gradient is edited, not pasted; the CSS string stays the storage format
            // because BackgroundLayer parses it and shared themes carry it. Direction is two
            // options, not an angle: the renderer snaps every angle to vertical or horizontal.
            component SGradient: Item {
                id: grad
                property string css: ""
                signal changed(string css)

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.sp(150)
                height: Theme.sp(58)

                // -- the same shape BackgroundLayer.parseCssGradient reads --
                readonly property var parsed: {
                    const inner = String(css).replace(/^.*linear-gradient\(/i, "").replace(/\)\s*$/, "")
                    const parts = inner.split(",").map((x) => x.trim()).filter((x) => x.length > 0)
                    let deg = 180, start = 0
                    if (parts.length && /deg|to /i.test(parts[0])) {
                        const m = parts[0].match(/(-?[\d.]+)deg/)
                        deg = m ? Number(m[1]) : 180
                        start = 1
                    }
                    const cs = parts.slice(start)
                    const stops = []
                    for (let i = 0; i < cs.length; ++i) {
                        const pm = cs[i].match(/(-?[\d.]+)%/)
                        const col = cs[i].replace(/\s*-?[\d.]+%\s*/, "").trim()
                        const pos = pm ? Number(pm[1]) / 100 : (cs.length > 1 ? i / (cs.length - 1) : 0)
                        if (col) stops.push({ pos: Math.max(0, Math.min(1, pos)), color: col })
                    }
                    if (stops.length < 2)
                        return { deg: deg, stops: [{ pos: 0, color: "#12203a" }, { pos: 1, color: "#0a0f1a" }] }
                    stops.sort((a, b) => a.pos - b.pos)
                    return { deg: deg, stops: stops }
                }
                readonly property bool vertical: !(parsed.deg > 45 && parsed.deg < 135)

                function emit_(deg, stops) {
                    const body = stops.slice().sort((a, b) => a.pos - b.pos)
                        .map((s) => s.color + " " + Math.round(s.pos * 100) + "%").join(", ")
                    changed("linear-gradient(" + Math.round(deg) + "deg, " + body + ")")
                }
                function setStopColor(i, c) {
                    const st = parsed.stops.map((s) => ({ pos: s.pos, color: s.color }))
                    st[i].color = String(c); emit_(parsed.deg, st)
                }
                function setStopPos(i, p) {
                    const st = parsed.stops.map((s) => ({ pos: s.pos, color: s.color }))
                    st[i].pos = Math.max(0, Math.min(1, p)); emit_(parsed.deg, st)
                }
                function addStop(p) {
                    const st = parsed.stops.map((s) => ({ pos: s.pos, color: s.color }))
                    // the colour already there, so a new stop starts invisible
                    // and becomes whatever you then choose
                    let near = st[0].color
                    for (const s of st) if (s.pos <= p) near = s.color
                    st.push({ pos: Math.max(0, Math.min(1, p)), color: near })
                    emit_(parsed.deg, st)
                }
                function removeStop(i) {
                    if (parsed.stops.length <= 2) return   // two is a gradient; one is a colour
                    const st = parsed.stops.map((s) => ({ pos: s.pos, color: s.color }))
                    st.splice(i, 1); emit_(parsed.deg, st)
                }

                Column {
                    anchors.fill: parent
                    spacing: Theme.gap(6)

                    // live preview, drawn the way the background will draw it
                    Rectangle {
                        id: bar
                        width: parent.width
                        height: Theme.sp(26)
                        radius: Theme.radiusSm
                        border.color: Theme.border
                        gradient: Gradient {
                            orientation: grad.vertical ? Gradient.Vertical : Gradient.Horizontal
                            GradientStop { position: grad.parsed.stops[0].pos
                                           color: grad.parsed.stops[0].color }
                            GradientStop { position: grad.parsed.stops[1].pos
                                           color: grad.parsed.stops[1].color }
                            GradientStop { position: grad.parsed.stops.length > 2 ? grad.parsed.stops[2].pos : 1
                                           color: grad.parsed.stops.length > 2 ? grad.parsed.stops[2].color
                                                                              : grad.parsed.stops[1].color }
                            GradientStop { position: grad.parsed.stops.length > 3 ? grad.parsed.stops[3].pos : 1
                                           color: grad.parsed.stops.length > 3 ? grad.parsed.stops[3].color
                                                                              : grad.parsed.stops[grad.parsed.stops.length - 1].color }
                        }
                        // click the bar where there is no handle to add one
                        MouseArea {
                            anchors.fill: parent
                            onClicked: (m) => grad.addStop(m.x / width)
                        }
                    }

                    // the stops, on a rail under the bar
                    Item {
                        width: parent.width
                        height: Theme.sp(16)
                        Surface {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 1
                            role: "border"
                        }
                        Repeater {
                            model: grad.parsed.stops.length
                            Rectangle {
                                required property int index
                                readonly property var st: grad.parsed.stops[index]
                                x: st.pos * (parent.width - width)
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.sp(14); height: Theme.sp(14)
                                radius: width / 2
                                color: st.color
                                border.color: hMa.containsMouse || hMa.drag.active
                                              ? Theme.accent : Theme.border
                                border.width: hMa.containsMouse || hMa.drag.active ? 2 : 1
                                MouseArea {
                                    id: hMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    drag.target: parent
                                    drag.axis: Drag.XAxis
                                    drag.minimumX: 0
                                    drag.maximumX: parent.parent.width - parent.width
                                    drag.threshold: 3
                                    onReleased: if (drag.active)
                                        grad.setStopPos(index, parent.x / (parent.parent.width - parent.width))
                                    onClicked: (m) => {
                                        if (m.button === Qt.RightButton) grad.removeStop(index)
                                        else colorPicker.open(st.color, ({ commit: (c) => grad.setStopColor(index, c) }))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            component SInput: Surface {
                property alias text: siField.text
                property string placeholder
                signal committed(string v)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.sp(150); height: Theme.sp(24) + Theme.inset("input", "top") + Theme.inset("input", "bottom")
                radius: Theme.radiusMd
                role: "button"
                borderWidth: 1
                borderRole: siField.activeFocus ? "borderStrong" : "border"
                TextInput {
                    id: siField
                    anchors.fill: parent
                    anchors.leftMargin: Theme.inset("input", "left")
                    anchors.rightMargin: Theme.inset("input", "right")
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    clip: true
                    font { pixelSize: Theme.fs(11); family: "monospace" }
                    onEditingFinished: parent.committed(text.trim())
                }
                InkText {
                    anchors.verticalCenter: parent.verticalCenter
                    x: Theme.inset("input", "left")   // where siField's text starts
                    visible: !siField.text.length && !siField.activeFocus
                    text: parent.placeholder
                    ink: "textFaint"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
            }

            // ============ GENERAL ============
            Column {
                visible: win.tab === "general"
                width: col.width

                SRow {
                    name: "Home source"
                    SSelect { value: Settings.homeSource
                              options: [ { value: "ytmusic", label: "YouTube Music" },
                                         { value: "youtube", label: "YouTube" } ]
                              onPicked: (v) => Settings.homeSource = v }
                }
                SRow {
                    name: "Prefetch next track"
                    desc: pfS.shown === 0 ? "Immediately"
                          : "At " + Math.round(pfS.shown) + "%"
                    SSlider { id: pfS; from: 0; to: 95; step: 5; value: Settings.prefetchPercent
                              onCommitted: (v) => Settings.prefetchPercent = Math.round(v) }
                }
                SRow {
                    name: "Crossfade"
                    desc: cfS.shown === 0 ? "Off" : cfS.shown.toFixed(1) + "s"
                    SSlider { id: cfS; from: 0; to: 12; step: 0.5; value: Settings.crossfadeSeconds
                              onCommitted: (v) => Settings.crossfadeSeconds = v }
                }
                SRow {
                    name: "Crossfade on skip"
                    SToggle { checked: win.cfOnSkip
                              onToggled: (v) => { win.cfOnSkip = v; Settings.uiSet("crossfadeOnSkip", v) } }
                }
                SRow {
                    name: "Skip silence"
                    SToggle { checked: Settings.silenceSkip
                              onToggled: (v) => Settings.silenceSkip = v }
                }
                SRow {
                    name: "Add to Library"
                    SSelect { value: String(Settings.uiGet("libraryDefault", "library"))
                              options: [ { value: "library", label: "Add only" },
                                         { value: "download", label: "Add + download" } ]
                              onPicked: (v) => { value = v; Settings.uiSet("libraryDefault", v) } }
                }
                SRow {
                    name: "Add to Playlist"
                    SSelect { value: String(Settings.uiGet("playlistDefault", "playlist"))
                              options: [ { value: "playlist", label: "Add only" },
                                         { value: "download", label: "Add + download" } ]
                              onPicked: (v) => { value = v; Settings.uiSet("playlistDefault", v) } }
                }
                SRow {
                    name: "Paste URL action"
                    SSelect { value: String(Settings.uiGet("pasteAction", "play"))
                              options: [ { value: "play", label: "Play" },
                                         { value: "search", label: "Search" } ]
                              onPicked: (v) => { value = v; Settings.uiSet("pasteAction", v) } }
                }
                SRow {
                    name: "Thumbnail quality"
                    SSelect { value: String(Settings.uiGet("thumbQuality", "medium"))
                              options: [ { value: "low", label: "Low" },
                                         { value: "medium", label: "Medium" },
                                         { value: "high", label: "High" } ]
                              onPicked: (v) => { value = v; Settings.uiSet("thumbQuality", v) } }
                }
                SRow {
                    name: "Scroll speed"
                    desc: Math.round(scS.shown) + (Math.round(scS.shown) === 1 ? " row" : " rows")
                    SSlider { id: scS; from: 1; to: 10; step: 1; value: win.scrollSpeed
                              onCommitted: (v) => { win.scrollSpeed = Math.round(v)
                                                    Settings.uiSet("scrollSpeed", Math.round(v)) } }
                }
                SRow {
                    name: "Tile growth"
                    desc: (Math.round(tgS.shown * 10) / 10) + "%"
                    SSlider { id: tgS; from: 0; to: 8; step: 0.5
                              value: win.tileGrowth
                              onCommitted: (v) => { win.tileGrowth = Math.round(v * 10) / 10
                                                    Settings.uiSet("tileGrowth", win.tileGrowth) } }
                }
                SRow {
                    name: "Fractional scaling fix"
                    desc: win.gridStep > 1 ? "" : "Not needed at this scale"
                    SToggle { checked: win.gridSnap
                              onToggled: (v) => { win.gridSnap = v; Settings.uiSet("gridSnap", v) } }
                }
                SRow {
                    name: "Download path"
                    desc: Settings.downloadPath
                    Item { }
                }
                SRow {
                    name: "Import local files"
                    SBtn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                           label: "Import…"; onClicked: importDialog.open() }
                }
            }

            // ============ PERSONALIZATION ============
            Column {
                visible: win.tab === "personalization"
                width: col.width

                SRow {
                    // One choice: a browser is an account as a profile is, and
                    // a signed-in one says whose it is.
                    name: "Account/Profile"
                    SSelect { value: { const a = Accounts.activeOf(win.accountEntries); return a ? a.key : "" }
                              options: win.accountEntries.map((e) => ({ value: e.key, label: e.label }))
                              onPicked: (v) => {
                                  const e = win.accountEntries.find((x) => x.key === v)
                                  if (e) Accounts.applyChoice(e, Settings)
                              } }
                }
                Item {   // profile management strip
                    visible: Settings.cookieSource === "guest"
                    width: col.width; height: 30
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: Theme.gap(16)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.gap(6)
                        SBtn { label: "New"
                               onClicked: winPrompt.promptDialog("New profile name", "", (name) => {
                                   if (!name || !name.trim()) return
                                   const n = name.trim()
                                   if (win.cookieProfiles.indexOf(n) >= 0) return
                                   sidecar.rpc("cookies/create", { name: n }, () => {
                                       Settings.cookieProfile = n
                                       win.refreshProfiles()
                                   })
                               }) }
                        SBtn { label: "Rename"
                               onClicked: winPrompt.promptDialog("Rename profile",
                                   Settings.cookieProfile, (name) => {
                                   if (!name || !name.trim()) return
                                   const n = name.trim()
                                   if (n === Settings.cookieProfile
                                       || win.cookieProfiles.indexOf(n) >= 0) return
                                   sidecar.rpc("cookies/rename",
                                       { oldName: Settings.cookieProfile, newName: n }, () => {
                                       Settings.cookieProfile = n
                                       win.refreshProfiles()
                                   })
                               }) }
                        SBtn { label: "Delete"; danger: true
                               visible: win.cookieProfiles.length > 1
                               onClicked: winPrompt.confirmDialog(
                                   "Delete profile \"" + Settings.cookieProfile + "\"?", (ok) => {
                                   if (ok !== true) return
                                   const dead = Settings.cookieProfile
                                   sidecar.rpc("cookies/delete", { name: dead }, () => {
                                       const rest = win.cookieProfiles.filter(p => p !== dead)
                                       Settings.cookieProfile = rest.length ? rest[0] : "Default"
                                       win.refreshProfiles()
                                   })
                               }) }
                    }
                }
                SRow {
                    visible: Settings.cookieSource === "guest"
                    name: "Import browser cookies"
                    desc: win.importResult
                    Row {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.gap(6)
                        SSelect { value: win.importBrowser
                                  options: win.browserOptions
                                  // clear the self-anchor: it conflicts inside a Row
                                  anchors.right: undefined; anchors.verticalCenter: undefined
                                  onPicked: (v) => win.importBrowser = v }
                        SBtn { label: win.importing ? "..." : "Import"
                               // an import already running: nothing to press
                               enabled: !win.importing
                               onClicked: {
                                   win.importing = true
                                   win.importResult = ""
                                   sidecar.rpc("cookies/import",
                                       { browser: win.importBrowser,
                                         profile: Settings.cookieProfile }, (r) => {
                                       win.importing = false
                                       win.importResult = (r.ok && r.result && r.result.count !== undefined)
                                           ? "Imported " + r.result.count + " cookies" : "Import failed"
                                   })
                               } }
                    }
                }
                SRow {
                    visible: Settings.cookieSource === "guest"
                    name: "Reset guest session"
                    SBtn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                           label: "Reset"; danger: true
                           onClicked: winPrompt.confirmDialog(
                               "Reset the guest session? Recommendations will start over.",
                               (ok) => { if (ok === true) sidecar.rpc("cookies/resetGuest",
                                   { profile: Settings.cookieProfile }, () => {}) }) }
                }
                SRow {
                    // there is nothing to report to without a session
                    visible: Settings.cookieSource !== "none"
                    name: "Improve recommendations"
                    SToggle { checked: Settings.sendPlayback
                              onToggled: (v) => Settings.sendPlayback = v }
                }
                SRow {
                    name: "YouTube language"
                    SearchSelect {
                        options: Locales.options(win.localeList)
                        value: Settings.language
                        placeholder: "System"
                        onPicked: (v) => Settings.language = v
                    }
                }
                SRow {
                    name: "YouTube region"
                    SearchSelect {
                        options: Locales.regionOptions(win.regionList)
                        value: Settings.region
                        placeholder: "System"
                        onPicked: (v) => Settings.region = v
                    }
                }
                SRow {
                    name: "Auto-generated lyrics"
                    SToggle { checked: Settings.lyricsAutoCaptions
                              onToggled: (v) => Settings.lyricsAutoCaptions = v }
                }
                SRow {
                    name: "yt-dlp channel"
                    SSelect { value: Settings.ytdlpChannel
                              options: [ { value: "stable", label: "Stable" },
                                         { value: "nightly", label: "Nightly" } ]
                              onPicked: (v) => sidecar.rpc("ytdlp/setChannel", { channel: v },
                                                           () => Settings.refresh()) }
                }
                SRow {
                    name: "Auto-tag new tracks"
                    SToggle { checked: Settings.metadataAutoEnrich === "new"
                              onToggled: (v) => Settings.metadataAutoEnrich = v ? "new" : "off" }
                }
                // which services tagging may contact — auto-tag, the library's
                // auto-tag button and the metadata editor's lookup alike
                SRow {
                    visible: win.autoTagOn
                    name: "Tag with MusicBrainz"
                    SToggle { checked: Settings.tagMusicBrainz
                              onToggled: (v) => Settings.tagMusicBrainz = v }
                }
                SRow {
                    visible: win.autoTagOn
                    name: "Tag with Deezer"
                    SToggle { checked: Settings.tagDeezer
                              onToggled: (v) => Settings.tagDeezer = v }
                }
                SRow {
                    visible: win.autoTagOn
                    name: "Tag with Last.fm"
                    SToggle { checked: Settings.tagLastfm
                              onToggled: (v) => Settings.tagLastfm = v }
                }
                // Last.fm is asked only with a key, so the key sits under its
                // switch and says so while it is missing.
                SRow {
                    visible: win.autoTagOn && Settings.tagLastfm
                    name: "Last.fm API key"
                    desc: Settings.lastfmApiKey.length ? "" : "Required · last.fm/api"
                    SInput { text: Settings.lastfmApiKey
                             placeholder: "Required"
                             onCommitted: (v) => Settings.lastfmApiKey = v }
                }
                SRow {
                    name: "Auto-tag library"
                    desc: win.enrichResult
                    Row {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.gap(6)
                        SBtn { label: win.enriching ? "..." : "Heuristic"
                               // one pass at a time
                               enabled: !win.enriching
                               onClicked: {
                                   win.enriching = true; win.enrichResult = ""
                                   sidecar.rpc("metadata/batchEnrich", { mode: "heuristic" }, (r) => {
                                       win.enriching = false
                                       win.enrichResult = (r.ok && r.result && r.result.count !== undefined)
                                           ? "Tagged " + r.result.count + " tracks (heuristic)" : "Failed"
                                   }, 600000)
                               } }
                        SBtn { label: win.enriching ? "..." : "API"
                               // one pass at a time
                               enabled: !win.enriching
                               onClicked: {
                                   win.enriching = true; win.enrichResult = ""
                                   sidecar.rpc("metadata/batchEnrich", { mode: "api+heuristic" }, (r) => {
                                       win.enriching = false
                                       win.enrichResult = (r.ok && r.result && r.result.count !== undefined)
                                           ? "Tagged " + r.result.count + " tracks (API + heuristic)" : "Failed"
                                   }, 600000)
                               } }
                    }
                }
                SRow {
                    name: "Art priority"
                    SSelect { value: String(Settings.uiGet("artPriority", "album"))
                              options: [ { value: "album", label: "Album art" },
                                         { value: "thumbnail", label: "Thumbnail" } ]
                              onPicked: (v) => { value = v; Settings.uiSet("artPriority", v) } }
                }
                SRow {
                    name: "Download all"
                    SBtn {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        label: "Download"
                        onClicked: {
                            const nd = Library.playAllTracks(false)
                                .filter((t) => !t.downloaded).map((t) => t.id)
                            if (nd.length) Library.downloadAll(nd)
                        }
                    }
                }
            }

            // ============ APPEARANCE ============
            Column {
                visible: win.tab === "appearance"
                width: col.width
                SRow {
                    name: "Mode"
                    SSelect { value: win.simpleAppearance ? "simple" : "full"
                              options: [ { value: "simple", label: "Simple" },
                                         { value: "full", label: "Full" } ]
                              onPicked: (v) => { win.simpleAppearance = v === "simple"
                                                 Settings.uiSet("appearanceMode", v) } }
                }
                Column {
                    width: col.width
                    visible: !win.simpleAppearance
                Repeater {
                    model: win.slotRows
                    delegate: SRow {
                        required property var modelData
                        name: modelData.label
                        SSelect { value: modelData.bound
                                  options: modelData.options
                                  onPicked: (v) => win.bindSlot(modelData.id, v) }
                    }
                }
                }
                // Take from a theme. Picking one stages it; the strip names it
                // and shows a chip per part, every one lit; Apply takes the
                // lit ones, Cancel none. Import adds a theme to the list and
                // stages nothing.
                Surface {
                    visible: win.staged.length > 0
                    width: col.width - Theme.inset("settings", "left") - Theme.inset("settings", "right"); x: Theme.inset("settings", "left")
                    height: visible ? stageCol.implicitHeight + Theme.gap(20) : 0
                    radius: Theme.radiusLg
                    role: "card"
                    borderRole: "border"; borderWidth: 1
                    Column {
                        id: stageCol
                        x: Theme.gap(12); y: Theme.gap(10)
                        width: parent.width - Theme.gap(24)
                        spacing: Theme.gap(8)
                        InkText {
                            text: "Take from " + win.stagedName
                            ink: "text"
                            font { pixelSize: Theme.fs(13); family: Theme.fontFamily; weight: Theme.weightMedium }
                        }
                        Flow {
                            width: parent.width
                            spacing: Theme.gap(4)
                            Repeater {
                                model: ThemeBackend.partsOfTheme(win.staged)
                                SelectTab {
                                    required property string modelData
                                    readonly property bool lit: win.stagedParts.indexOf(modelData) >= 0
                                    style: Theme.chips
                                    label: win.partLabels[modelData] || modelData
                                    active: lit
                                    hover: tpMa.containsMouse; pressed: tpMa.pressed
                                    fontSize: 11
                                    width: implicitWidth; height: Theme.ctl(22)
                                    MouseArea { id: tpMa; anchors.fill: parent; hoverEnabled: true
                                                onClicked: {
                                                    const l = win.stagedParts.filter(p => p !== parent.modelData)
                                                    if (!parent.lit) l.push(parent.modelData)
                                                    win.stagedParts = l
                                                } }
                                }
                            }
                        }
                        Row {
                            anchors.right: parent.right
                            spacing: Theme.gap(6)
                            SBtn { label: "Apply"
                                   onClicked: { ThemeBackend.applyThemeParts(win.staged, win.stagedParts); win.staged = "" } }
                            SBtn { label: "Cancel"; onClicked: win.staged = "" }
                        }
                    }
                }
                // save as theme, with a choice per part
                Surface {
                    visible: win.saving
                    width: col.width - Theme.inset("settings", "left") - Theme.inset("settings", "right"); x: Theme.inset("settings", "left")
                    height: visible ? saveCol.implicitHeight + Theme.gap(20) : 0
                    radius: Theme.radiusLg
                    role: "card"
                    borderRole: "border"; borderWidth: 1
                    Column {
                        id: saveCol
                        x: Theme.gap(12); y: Theme.gap(10)
                        width: parent.width - Theme.gap(24)
                        spacing: Theme.gap(6)
                        Row {
                            width: parent.width
                            spacing: Theme.gap(8)
                            InkText { anchors.verticalCenter: parent.verticalCenter; text: "Save as"; ink: "text"
                                      font { pixelSize: Theme.fs(13); family: Theme.fontFamily; weight: Theme.weightMedium } }
                            Surface {
                                width: parent.width - 60; height: Theme.ctl(26)
                                radius: Theme.radiusMd; role: "input"; borderRole: "border"; borderWidth: 1
                                TextInput {
                                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    text: win.saveName; color: Theme.text; selectByMouse: true
                                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                                    onTextChanged: win.saveName = text
                                }
                            }
                        }
                        Repeater {
                            model: ThemeBackend.themeParts()
                            Item {
                                id: partRow
                                required property string modelData
                                width: saveCol.width; height: Theme.ctl(26)
                                InkText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                          text: win.partLabels[modelData]; ink: "textSoft"
                                          font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                                Row {
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.gap(2)
                                    Repeater {
                                        model: [ { v: "own", l: "Include" }, { v: "off", l: "Off" } ]
                                        SelectTab {
                                            required property var modelData
                                            // the row's part, by id: counting
                                            // parents reaches past the row to
                                            // the column
                                            readonly property string part: partRow.modelData
                                            style: Theme.chips
                                            label: modelData.l
                                            active: win.saveChoice[part] === modelData.v
                                            hover: scMa.containsMouse; pressed: scMa.pressed
                                            fontSize: 11
                                            width: implicitWidth; height: Theme.ctl(22)
                                            MouseArea { id: scMa; anchors.fill: parent; hoverEnabled: true
                                                        onClicked: { const c = Object.assign({}, win.saveChoice); c[parent.part] = parent.modelData.v; win.saveChoice = c } }
                                        }
                                    }
                                }
                            }
                        }
                        Row {
                            anchors.right: parent.right
                            spacing: Theme.gap(6)
                            SBtn { label: "Save"
                                   onClicked: { ThemeBackend.saveThemeAs(win.saveName, win.saveChoice); win.saving = false } }
                            SBtn { label: "Cancel"; onClicked: win.saving = false }
                        }
                    }
                }
                SRow {
                    name: "Theme"
                    desc: ThemeBackend.dirty ? "Custom · " + ThemeBackend.activeName : ThemeBackend.activeName
                    SSelect { value: win.staged.length > 0 ? win.staged : ThemeBackend.activeId
                              options: ThemeBackend.themes.map(t => ({ value: t.id, label: t.name }))
                              onPicked: (v) => win.stage(v) }
                }
                Item {
                    width: col.width; height: 30
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: Theme.gap(16)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.gap(6)
                        SBtn { label: "Save as theme"; onClicked: win.startSave() }
                        SBtn { visible: ThemeBackend.dirty && !ThemeBackend.activeBuiltIn; label: "Save"
                               onClicked: ThemeBackend.saveActive() }
                        SBtn { label: "Export"
                               onClicked: Portal.saveFile("theme-export", "Export theme",
                                   ThemeBackend.activeName + ".json", "Theme", ["*.json"]) }
                        SBtn { label: "Import"
                               onClicked: Portal.openFile("theme-import", "Import theme",
                                   "Theme", ["*.json"], false) }
                        SBtn { visible: !ThemeBackend.activeBuiltIn
                               label: "Delete"; danger: true
                               onClicked: winPrompt.confirmDialog(
                                   "Delete theme \"" + ThemeBackend.activeName + "\"?",
                                   (ok) => { if (ok === true) ThemeBackend.deleteTheme(ThemeBackend.activeId) }) }
                    }
                }

                // ---- simple: the theme as the colours it is made of --------
                // One row per colour, however many roles, layers and stops use it; a pick replaces
                // all of them in one palette write. The list is computed from the palette, so it
                // has no state to keep in step.
                Column {
                    width: col.width
                    visible: win.simpleAppearance
                    Repeater {
                        model: win.colourGroupList
                        delegate: SRow {
                            id: cgRow
                            required property var modelData
                            name: modelData.colour
                            desc: modelData.count + (modelData.count === 1 ? " place" : " places")
                            reserve: 240
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(8)
                                SBtn {
                                    anchors.verticalCenter: parent.verticalCenter
                                    label: "Make swatch"
                                    onClicked: win.swatchFromGroup(cgRow.modelData)
                                }
                                Surface {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Theme.ctl(40); height: Theme.btnH; radius: Theme.radiusMd
                                    role: Theme.faceOf("button", cgMa.containsMouse, cgMa.pressed)
                                    borderWidth: 1
                                    borderRole: cgMa.containsMouse ? "borderStrong" : "border"
                                    EntryChip {
                                        anchors.centerIn: parent
                                        anchors.horizontalCenterOffset: Theme.pressShift(cgMa.pressed)
                                        anchors.verticalCenterOffset: Theme.pressShift(cgMa.pressed)
                                        width: Theme.ctl(24); height: Theme.ctl(14)
                                        entry: String(Theme.colourFromHex(cgRow.modelData.colour))
                                    }
                                    MouseArea {
                                        id: cgMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: colorPicker.open(String(Theme.colourFromHex(cgRow.modelData.colour)), ({
                                            commit: (c) => win.recolourGroup(cgRow.modelData, c),
                                            preview: (c) => win.previewGroup(cgRow.modelData, c) }))
                                    }
                                }
                            }
                        }
                    }
                    SRow {
                        name: "Interface size"
                        desc: "×" + simUiS.shown.toFixed(2)
                        SSlider { id: simUiS; from: 0.8; to: 1.6; step: 0.05
                                  value: Number(win.ts("uiScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("uiScale", v) }
                    }
                    SRow {
                        name: "Opacity"
                        desc: Math.round(simOpS.shown * 100) + "%"
                        SSlider { id: simOpS; from: 0.1; to: 1; step: 0.05
                                  value: Number(win.ts("opacityScale", 1))
                                  onCommitted: (v) => ThemeBackend.setMasterOpacity(v) }
                    }
                    SRow {
                        name: "Corners"
                        SSelect { value: String(win.ts("cornerStyle", "rounded"))
                                  options: [ { value: "rounded", label: "Rounded" },
                                             { value: "squared", label: "Squared" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("cornerStyle", v) }
                    }
                    SRow {
                        name: "Font"
                        // not a description: what went wrong and what it did
                        desc: Theme.fontMissing
                              ? Theme.fontRequested + " is not installed — using " + Theme.fontFamily
                              : ""
                        SearchSelect {
                            id: simFontPick
                            property var families: []
                            options: families
                            value: win.ts("font", "")
                            placeholder: "Red Hat Display"
                            previewFont: true
                            popupHeight: 300
                            onOpening: if (!families.length) families = win.fontOptions()
                            onPicked: (v) => ThemeBackend.setThemeSetting("font", v)
                        }
                    }
                }

                // ---- FULL: every section ----------------------------------
                Column {
                    width: col.width
                    visible: !win.simpleAppearance
                SectionHead { title: "TEXT & SYMBOLS"; kind: "palette" }
                Column {
                    width: col.width
                    visible: win.secOpen("palette")
                    SectionTools { title: "TEXT & SYMBOLS"; kind: "palette" }
                    // Ink rows: swatch and opacity, the same shape as a surface.
                    Repeater {
                        model: [
                            { key: "text", label: "Text" },
                            { key: "textSoft", label: "Text soft" },
                            { key: "textDim", label: "Text dim" },
                            { key: "textFaint", label: "Text faint" },
                            { key: "textOverArt", label: "Text over artwork" },
                            { key: "control", label: "Controls" },
                            { key: "controlOff", label: "Controls off" },
                            { key: "controlHover", label: "Controls hover" },
                            { key: "textOnAccent", label: "Text on accent" },
                            { key: "textOnSelected", label: "Text on selected" },
                            { key: "textOnActive", label: "Text on active button" },
                            { key: "textOnTitle", label: "Text on title bar" },
                            { key: "close", label: "Close" },
                            { key: "closeHover", label: "Close hover" },
                            { key: "titleGlyph", label: "Title bar buttons" },
                            { key: "titleGlyphHover", label: "Title bar buttons hover" },
                            { key: "titleGlyphActive", label: "Title bar buttons on" },
                            { key: "highlight", label: "Highlight" },
                        ]
                        Column {
                            id: inkBlock
                            required property var modelData
                            readonly property string key: modelData.key
                            readonly property var entry: Theme.entryOf(key)
                            readonly property var eff: Theme.inkRole(key).effect
                            readonly property bool effOn: eff.kind !== "off"
                            width: col.width
                            SRow {
                                id: inkRow
                                readonly property real own: Theme.opacityMap[inkBlock.key] !== undefined
                                                            ? Theme.opacityMap[inkBlock.key] : 1
                                name: inkBlock.modelData.label
                                desc: {
                                    const src = Theme.sourceOf(inkBlock.entry), m = Theme.blendOf(inkBlock.entry)
                                    const parts = []
                                    if (src !== "colour") parts.push(Theme.sourceName(src))
                                    if (m.length > 0) parts.push(m)
                                    parts.push(Math.round(inkS.shown * 100) + "%")
                                    const sw = win.usesSwatch(entry); if (sw.length) parts.push(sw)
                                    return parts.join(" · ")
                                }
                                Surface {   // swatch button
                                    anchors.right: inkS.left; anchors.rightMargin: Theme.gap(10)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Theme.ctl(40); height: Theme.btnH; radius: Theme.radiusMd
                                    role: Theme.faceOf("button", isMa.containsMouse, isMa.pressed)
                                    borderWidth: 1
                                    borderRole: isMa.containsMouse ? "borderStrong" : "border"
                                    EntryChip {
                                        anchors.centerIn: parent
                                        anchors.horizontalCenterOffset: Theme.pressShift(isMa.pressed)
                                        anchors.verticalCenterOffset: Theme.pressShift(isMa.pressed)
                                        width: Theme.ctl(24); height: Theme.ctl(14)
                                        entry: inkBlock.entry
                                        fallback: Theme[inkBlock.key]
                                    }
                                    MouseArea {
                                        id: isMa; anchors.fill: parent; hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: (m) => m.button === Qt.RightButton ? win.recentMenu(inkBlock.key, isMa)
                                                                                      : win.pickPalette(inkBlock.key, inkBlock.entry, true)
                                    }
                                }
                                SSlider { id: inkS; from: 0; to: 1; step: 0.05
                                          value: inkRow.own
                                          onCommitted: (v) => win.setRoleOpacity(inkBlock.key, v) }
                            }
                            // the ink's effect: a halo beneath its words. Real where
                            // a component can draw one, Qt's 1px style elsewhere.
                            EffectRows { key: inkBlock.key }
                        }
                    }
                }

                SectionHead { title: "COLOURS"; kind: "surfaces" }
                Column {
                    width: col.width
                    visible: win.secOpen("surfaces")
                    SectionTools { title: "COLOURS"; kind: "surfaces" }
                    Flow {
                        width: col.width - 32
                        x: 16
                        spacing: Theme.gap(6)
                        Repeater {
                            model: win.accentRows
                            Surface {
                                required property var modelData
                                width: palLabel.implicitWidth + 38; height: Theme.btnH
                                radius: Theme.radiusMd
                                role: Theme.faceOf("button", palMa.containsMouse, palMa.pressed)
                                borderWidth: 1
                                borderRole: palMa.containsMouse ? "borderStrong" : "border"
                                readonly property int shift: Theme.pressShift(palMa.pressed)
                                EntryChip {
                                    x: 5 + parent.shift
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: parent.shift
                                    width: Theme.ctl(16); height: Theme.ctl(16)
                                    // an entry a theme does not set shows what Theme resolves it to
                                    entry: ThemeBackend.palette[parent.modelData.key]
                                    fallback: Theme[parent.modelData.key]
                                }
                                // a dot on the chip: this role uses a theme swatch
                                Rectangle {
                                    visible: win.usesSwatch(ThemeBackend.palette[parent.modelData.key]).length > 0
                                    x: 5 + Theme.ctl(16) - 4 + parent.shift
                                    y: (parent.height - Theme.ctl(16)) / 2 - 2 + parent.shift
                                    width: 6; height: 6; radius: 3
                                    color: Theme.highlight; border.color: Theme.button; border.width: 1
                                }
                                InkText { id: palLabel; x: 27 + parent.shift
                                       anchors.verticalCenter: parent.verticalCenter
                                       anchors.verticalCenterOffset: parent.shift
                                       text: parent.modelData.label
                                       ink: "text"
                                       font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                                MouseArea {
                                    id: palMa; anchors.fill: parent; hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: (m) => m.button === Qt.RightButton ? win.recentMenu(parent.modelData.key, palMa)
                                                                                  : win.pickPalette(parent.modelData.key,
                                                                                                    Theme.entryOf(parent.modelData.key), false)
                                }
                            }
                        }
                    }
                    Item { width: 1; height: Theme.gap(8) }
                    // One row per role: the swatch opens the picker (colour,
                    // source, blend, amounts), the slider is the role's own
                    // opacity.
                    Repeater {
                        model: win.surfaceRows.concat(win.ownRows)
                        SRow {
                            id: roleRow
                            required property var modelData
                            readonly property string key: modelData.key
                            readonly property var entry: Theme.entryOf(key)
                            readonly property real own: Theme.opacityMap[key] !== undefined
                                                        ? Theme.opacityMap[key] : 1
                            name: modelData.label
                            desc: {
                                const src = Theme.sourceOf(entry), m = Theme.blendOf(entry)
                                const parts = []
                                if (src !== "colour") parts.push(Theme.sourceName(src))
                                if (m.length > 0) parts.push(m)
                                parts.push(Math.round(roleS.shown * 100) + "%")
                                const sw = win.usesSwatch(entry); if (sw.length) parts.push(sw)
                                return parts.join(" · ")
                            }
                            Surface {   // swatch button
                                anchors.right: roleS.left; anchors.rightMargin: Theme.gap(10)
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.ctl(40); height: Theme.btnH; radius: Theme.radiusMd
                                role: Theme.faceOf("button", rsMa.containsMouse, rsMa.pressed)
                                borderWidth: 1
                                borderRole: rsMa.containsMouse ? "borderStrong" : "border"
                                EntryChip {
                                    anchors.centerIn: parent
                                    anchors.horizontalCenterOffset: Theme.pressShift(rsMa.pressed)
                                    anchors.verticalCenterOffset: Theme.pressShift(rsMa.pressed)
                                    width: Theme.ctl(24); height: Theme.ctl(14)
                                    entry: roleRow.entry
                                    fallback: Theme[roleRow.key]
                                }
                                MouseArea {
                                    id: rsMa; anchors.fill: parent; hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: (m) => m.button === Qt.RightButton ? win.recentMenu(roleRow.key, rsMa)
                                                                                  : win.pickPalette(roleRow.key, roleRow.entry, true)
                                }
                            }
                            SSlider { id: roleS; from: 0; to: 1; step: 0.05
                                      value: roleRow.own
                                      onCommitted: (v) => win.setRoleOpacity(roleRow.key, v) }
                        }
                    }
                }

                // The theme's swatches, here as well as in the picker's shelf:
                // one row each, the colour opening the picker on it, and what
                // comes back written to the swatch and to every role using it.
                SectionHead { title: "SWATCHES"; kind: "swatches"; presets: false }
                Column {
                    width: col.width
                    visible: win.secOpen("swatches")
                    Repeater {
                        model: win.themeSwatchList
                        SRow {
                            id: swRow
                            required property var modelData
                            readonly property var uses: (Theme.p, Theme.rolesFrom(modelData.id))
                            name: modelData.name
                            desc: uses.length === 0 ? "" : uses.length + (uses.length === 1 ? " role" : " roles")
                            Row {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(6)
                                Surface {   // the swatch itself
                                    width: Theme.ctl(40); height: Theme.btnH; radius: Theme.radiusMd
                                    role: Theme.faceOf("button", swMa.containsMouse, swMa.pressed)
                                    borderWidth: 1
                                    borderRole: swMa.containsMouse ? "borderStrong" : "border"
                                    EntryChip { anchors.centerIn: parent; width: Theme.ctl(24); height: Theme.ctl(14)
                                                anchors.horizontalCenterOffset: Theme.pressShift(swMa.pressed)
                                                anchors.verticalCenterOffset: Theme.pressShift(swMa.pressed)
                                                entry: swRow.modelData.entry }
                                    MouseArea {
                                        id: swMa; anchors.fill: parent; hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: (m) => m.button === Qt.RightButton ? win.swatchMenu(swRow.modelData, swMa)
                                                                                      : colorPicker.open(swRow.modelData.entry, ({
                                            commit: (c) => Theme.setThemeSwatch(swRow.modelData.id, swRow.modelData.name, c),
                                            blend: true, adaptive: true }))
                                    }
                                }
                                SBtn { label: "Remove"; danger: true
                                       onClicked: win.dropThemeSwatch(swRow.modelData.id) }
                            }
                        }
                    }
                    SRow {
                        name: "New swatch"
                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(6)
                            SInput { id: newSwName; anchors.right: undefined; anchors.verticalCenter: parent.verticalCenter; width: Theme.sp(110) }
                            SBtn { label: "Add"
                                   // an unnamed swatch is not one
                                   enabled: newSwName.text.trim().length > 0
                                   onClicked: {
                                       const n = newSwName.text.trim()
                                       colorPicker.open(Theme.text.toString(), ({
                                           commit: (c) => { Theme.setThemeSwatch(win.newSwatchId(), n, c); newSwName.text = "" },
                                           blend: true, adaptive: true }))
                                   } }
                        }
                    }
                }

                SectionHead { title: "WINDOW"; kind: "window" }
                Column {
                    width: col.width
                    visible: win.secOpen("window")
                    SectionTools { title: "WINDOW"; kind: "window" }
                    SRow {
                        name: "Header"
                        SSelect { value: String(win.ts("header", "stacked"))
                                  options: [ { value: "stacked", label: "Stacked" }, { value: "combined", label: "Combined" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("header", v) }
                    }
                    SRow {
                        name: "Window corners"
                        desc: Math.round(wrS.shown) + "px"
                        SSlider { id: wrS; from: 0; to: 16; step: 1
                                  value: Number(win.ts("windowRadius", 4))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("windowRadius", Math.round(v)) }
                    }
                    SRow {
                        name: "Bottom corners"
                        desc: botRS.shown < 0 ? "Same" : Math.round(botRS.shown) + "px"
                        SSlider { id: botRS; from: -1; to: 16; step: 1
                                  value: Number(win.ts("windowRadiusBottom", -1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("windowRadiusBottom", Math.round(v)) }
                    }
                    SRow {
                        name: "Window shape"
                        SSelect { value: win.shapeKind
                                  options: [ { value: "", label: "Corners" }, { value: "corners", label: "Each corner" },
                                             { value: "path", label: "Path" }, { value: "image", label: "Image" } ]
                                  onPicked: (v) => win.setShapeKind(v) }
                    }
                    Repeater {
                        model: win.shapeKind === "corners" ? [ { i: 0, label: "Top left" }, { i: 1, label: "Top right" },
                                                              { i: 2, label: "Bottom right" }, { i: 3, label: "Bottom left" } ] : []
                        SRow {
                            id: cornerRow
                            required property var modelData
                            readonly property var corner: (win.shapeSpec.corners || [])[modelData.i] || ({ style: "round", size: 0 })
                            name: modelData.label
                            desc: Math.round(Number(corner.size) || 0) + "px"
                            Row {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(8)
                                SSelect { anchors.right: undefined
                                          value: String(cornerRow.corner.style || "round")
                                          options: [ { value: "round", label: "Round" }, { value: "cut", label: "Cut" },
                                                     { value: "square", label: "Square" } ]
                                          onPicked: (v) => win.setCorner(cornerRow.modelData.i, "style", v) }
                                SSlider { anchors.right: undefined
                                          from: 0; to: 32; step: 1; value: Number(cornerRow.corner.size) || 0
                                          onCommitted: (v) => win.setCorner(cornerRow.modelData.i, "size", Math.round(v)) }
                            }
                        }
                    }
                    Item {   // the shape, edited as the shape (ShapeEditor)
                        width: col.width
                        visible: win.shapeKind === "path" || win.shapeKind === "image"
                        height: visible ? shapeEd.implicitHeight + 2 * Theme.inset("settings", "top") : 0
                        ShapeEditor {
                            id: shapeEd
                            x: Theme.inset("settings", "left")
                            y: Theme.inset("settings", "top")
                            width: parent.width - Theme.inset("settings", "left") - Theme.inset("settings", "right")
                            spec: win.shapeSpec
                            onChanged: (next) => ThemeBackend.setThemeSetting("windowShape", next)
                        }
                    }
                    SRow {
                        name: "Too small for the edges"
                        visible: win.shapeKind === "path" || win.shapeKind === "image"
                        SSelect { value: String(win.shapeSpec.fit || "squeeze")
                                  options: [ { value: "squeeze", label: "Squeeze" }, { value: "crop", label: "Keep edges" } ]
                                  onPicked: (v) => win.shapeWith("fit", v) }
                    }
                    SRow {
                        name: "Image scale"
                        visible: win.shapeKind === "image"
                        SInput { text: String(win.shapeSpec.scale || 1)
                                 placeholder: "2"
                                 onCommitted: (v) => { const n = win.shapeNums(v, 1); if (n && n[0] > 0) win.shapeWith("scale", n[0]) } }
                    }
                    SRow {
                        name: "Header surfaces"
                        SSelect { value: String(win.ts("headerGroup", "separate"))
                                  options: [ { value: "separate", label: "Separate" }, { value: "all", label: "One surface" },
                                             { value: "titleSearch", label: "Title + search" },
                                             { value: "searchTabs", label: "Search + tabs" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("headerGroup", v) }
                    }
                    SRow {
                        name: "Page corners"
                        SSelect { value: String(win.ts("pageCorners", "none"))
                                  options: [ { value: "none", label: "Square" }, { value: "bottom", label: "Bottom" },
                                             { value: "all", label: "All" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("pageCorners", v) }
                    }
                    SRow {
                        name: "Corner style"
                        SSelect { value: String(win.ts("cornerStyle", "rounded"))
                                  options: [ { value: "rounded", label: "Rounded" },
                                             { value: "squared", label: "Squared" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("cornerStyle", v) }
                    }
                    SRow {
                        name: "Window ground"
                        SSelect { value: win.ts("windowOverBackground", false) === true
                                         ? "over" : "under"
                                  options: [ { value: "under", label: "Under background" },
                                             { value: "over", label: "Over background" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting(
                                      "windowOverBackground", v === "over") }
                    }
                    SRow {
                        name: "Border"
                        SToggle { checked: win.ts("windowBorder", false) === true
                                  onToggled: (v) => ThemeBackend.setThemeSetting("windowBorder", v) }
                    }
                    Column {
                        width: parent.width
                        visible: Theme.windowBorder
                        SRow {
                            name: "Shape"
                            SSelect { value: String(win.ts("windowBorderFit", "window"))
                                      options: [ { value: "window", label: "Whole window" },
                                                 { value: "parts", label: "Around each part" } ]
                                      onPicked: (v) => ThemeBackend.setThemeSetting("windowBorderFit", v) }
                        }
                        SRow {
                            name: "Colour"
                            RoleChip { roleName: "windowBorder" }
                        }
                        SRow {
                            name: "Width"
                            visible: !Theme.borderSides
                            desc: Math.round(bwS.shown) + "px"
                            SSlider { id: bwS; from: 1; to: 16; step: 1; value: Theme.windowBorderWidth
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("windowBorderWidth", Math.round(v)) }
                        }
                        SRow {
                            name: "Separate sides"
                            SToggle { checked: Theme.borderSides
                                      onToggled: (v) => {
                                          // start each side from the width in use, so turning it on changes nothing
                                          if (v) for (const k of ["borderLeft", "borderTop", "borderRight", "borderBottom"])
                                              ThemeBackend.setThemeSetting(k, Theme.windowBorderWidth)
                                          ThemeBackend.setThemeSetting("borderSides", v)
                                      } }
                        }
                        Repeater {
                            model: Theme.borderSides ? [ { k: "borderLeft", l: "Left" }, { k: "borderTop", l: "Top" },
                                                         { k: "borderRight", l: "Right" }, { k: "borderBottom", l: "Bottom" } ] : []
                            SRow {
                                id: sideRow
                                required property var modelData
                                name: modelData.l
                                desc: Math.round(sideS.shown) + "px"
                                SSlider { id: sideS; from: 0; to: 16; step: 1; value: Theme[sideRow.modelData.k]
                                          onCommitted: (v) => ThemeBackend.setThemeSetting(sideRow.modelData.k, Math.round(v)) }
                            }
                        }
                        SRow {
                            name: "Outer line"
                            desc: Math.round(olS.shown) + "px"
                            SSlider { id: olS; from: 0; to: 3; step: 1; value: Number(win.ts("borderOuterWidth", 0))
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("borderOuterWidth", Math.round(v)) }
                        }
                        SRow {
                            name: "Outer line colour"
                            visible: Theme.borderOuterWidth > 0
                            RoleChip { roleName: "windowBorderOuter" }
                        }
                        SRow {
                            name: "Inner line"
                            desc: Math.round(ilS.shown) + "px"
                            SSlider { id: ilS; from: 0; to: 3; step: 1; value: Number(win.ts("borderInnerWidth", 0))
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("borderInnerWidth", Math.round(v)) }
                        }
                        SRow {
                            name: "Inner line colour"
                            visible: Theme.borderInnerWidth > 0
                            RoleChip { roleName: "windowBorderInner" }
                        }
                        SRow {
                            name: "Outer edge blur"
                            desc: Math.round(sbo.shown) + "px"
                            SSlider { id: sbo; from: 0; to: 24; step: 1; value: Number(win.ts("borderSoftOuter", 0))
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("borderSoftOuter", Math.round(v)) }
                        }
                        SRow {
                            name: "Inner edge blur"
                            desc: Math.round(sbi.shown) + "px"
                            SSlider { id: sbi; from: 0; to: 24; step: 1; value: Number(win.ts("borderSoftInner", 0))
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("borderSoftInner", Math.round(v)) }
                        }
                        SRow {
                            name: "Blur curve"
                            visible: Theme.borderSoftOuter > 0 || Theme.borderSoftInner > 0
                            SSelect {
                                options: [{ value: "linear", label: "Linear" }, { value: "smooth", label: "Smooth" },
                                          { value: "glow", label: "Glow" }]
                                value: Theme.borderSoftCurve
                                onPicked: (v) => ThemeBackend.setThemeSetting("borderSoftCurve", v)
                            }
                        }
                        SRow {
                            name: "Band edge blur"
                            visible: win.bandList.length > 1
                            desc: Math.round(sbb.shown) + "px"
                            SSlider { id: sbb; from: 0; to: 16; step: 1; value: Number(win.ts("borderSoftBands", 0))
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("borderSoftBands", Math.round(v)) }
                        }
                        SRow {
                            name: "Frame bands"
                            desc: win.bandList.length ? win.bandList.length + "" : ""
                            Row {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(6)
                                SBtn { label: "Add"; onClicked: win.addBand() }
                                SBtn { label: "From lines"; visible: win.bandList.length > 0
                                       onClicked: win.setBands([]) }
                            }
                        }
                        Repeater {
                            model: win.bandList.length
                            SRow {
                                id: bandRow
                                required property int index
                                readonly property var band: win.bandList[index]
                                name: "Band " + (index + 1)
                                desc: Math.round(Number(band.width) || 0) + "px"
                                      + (band.role.length ? " \u00b7 " + win.bandRoleLabel(band.role) : "")
                                Row {
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.gap(6)
                                    SSlider { anchors.right: undefined
                                              from: 0; to: 16; step: 1; value: Number(bandRow.band.width) || 0
                                              onCommitted: (v) => win.setBand(bandRow.index, "width", Math.round(v)) }
                                    BandChip { index: bandRow.index; band: bandRow.band }
                                    SBtn { label: "Remove"
                                           onClicked: { const l = win.bandList; l.splice(bandRow.index, 1); win.setBands(l) } }
                                }
                            }
                        }
                        SRow {
                            name: "Title bar in border"
                            SToggle { checked: Theme.borderTitle
                                      onToggled: (v) => ThemeBackend.setThemeSetting("borderTitle", v) }
                        }
                        SRow {
                            name: "Title rim"
                            visible: Theme.borderTitle
                            desc: Math.round(trS.shown) + "px"
                            SSlider { id: trS; from: 0; to: 16; step: 1; value: Number(win.ts("borderTitleRim", 0))
                                      onCommitted: (v) => ThemeBackend.setThemeSetting("borderTitleRim", Math.round(v)) }
                        }
                        SRow {
                            name: "Title rim fade"
                            visible: Theme.borderTitle
                            SToggle { checked: Theme.borderTitleFade
                                      onToggled: (v) => ThemeBackend.setThemeSetting("borderTitleFade", v) }
                        }
                        SRow {
                            name: "Border when maximised"
                            SToggle { checked: Theme.borderMaximized
                                      onToggled: (v) => ThemeBackend.setThemeSetting("borderMaximized", v) }
                        }
                    }

                }

                SectionHead { title: "FONT"; kind: "type" }
                Column {
                    width: col.width
                    visible: win.secOpen("type")
                    SectionTools { title: "FONT"; kind: "type" }
                    SRow {
                        name: "Font"
                        // not a description: what went wrong and what it did
                        desc: Theme.fontMissing
                              ? Theme.fontRequested + " is not installed — using "
                                + Theme.fontFamily
                              : ""
                        SearchSelect {
                            id: fontPick
                            // built on first open: Qt.fontFamilies() walks the
                            // system's font config, and there is no reason to do
                            // that before anyone looks at this row
                            property var families: []
                            options: families
                            value: win.ts("font", "")
                            placeholder: "Red Hat Display"
                            previewFont: true
                            popupHeight: 300
                            onOpening: if (!families.length) families = win.fontOptions()
                            onPicked: (v) => ThemeBackend.setThemeSetting("font", v)
                        }
                    }
                    SRow {
                        name: "Font weight"
                        SSelect { value: String(win.ts("fontWeight", 400))
                                  options: [ { value: "300", label: "Light (300)" },
                                             { value: "400", label: "Normal (400)" },
                                             { value: "500", label: "Medium (500)" },
                                             { value: "600", label: "Semibold (600)" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("fontWeight", Number(v)) }
                    }
                    SRow {
                        name: "Title size"
                        desc: Math.round(titleFsS.shown)
                        SSlider { id: titleFsS; from: 9; to: 20; step: 1; value: Theme.titleFontSize
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("titleFontSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Title weight"
                        SSelect { value: String(win.ts("titleFontWeight", 0))
                                  options: [ { value: "0", label: "Medium" },
                                             { value: "400", label: "Normal (400)" },
                                             { value: "600", label: "Semibold (600)" },
                                             { value: "700", label: "Bold (700)" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("titleFontWeight", Number(v)) }
                    }
                }

                SectionHead { title: "TRANSPARENCY"; kind: "transparency" }
                Column {
                    width: col.width
                    visible: win.secOpen("transparency")
                    SectionTools { title: "TRANSPARENCY"; kind: "transparency" }
                    // No "scheme" row: this section's presets and BEHAVIOUR's
                    // cover what a scheme set. The kind stays registered so an
                    // exported scheme preset still imports.
                    SRow {
                        name: "Master opacity"
                        desc: Math.round(osS.shown * 100) + "%"
                        SSlider { id: osS; from: 0.1; to: 1; step: 0.05
                                  value: Number(win.ts("opacityScale", 1))
                                  // sets every surface that is not floating to this, and
                                  // is what a surface without a value of its own gets
                                  onCommitted: (v) => ThemeBackend.setMasterOpacity(v) }
                    }
                    SRow {
                        name: "Glass blur"
                        desc: WindowCtl.blurAvailable() ? ""
                              : "Needs kf6-kwindowsystem-devel at build time"
                        SSelect { value: String(win.ts("glassBlur", "off"))
                                  options: [ { value: "off", label: "Off" },
                                             { value: "always", label: "Always" },
                                             { value: "hover", label: "On hover" },
                                             { value: "away", label: "When away" },
                                             { value: "focus", label: "When focused" },
                                             { value: "unfocus", label: "On focus loss" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("glassBlur", v) }
                    }
                    SRow {
                        // Shown whenever the compositor has the effect: setting one
                        // of these makes melo request glass by itself, because that
                        // is the only thing the contrast can travel on since Plasma
                        // 6.5 merged the two effects. See Main.qml applyBlur.
                        visible: WindowCtl.contrastAvailable()
                        name: "Glass saturation"
                        desc: "×" + glyphSizeS.shown.toFixed(2)
                        SSlider { id: glyphSizeS; from: 0; to: 2; step: 0.05
                                  value: Number(win.ts("glassSaturation", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("glassSaturation", v) }
                    }
                    SRow {
                        visible: WindowCtl.contrastAvailable()
                        name: "Glass contrast"
                        desc: "×" + gcS.shown.toFixed(2)
                        // Negative inverts what is behind the window. KWin's
                        // background contrast is an affine ramp on the desktop
                        // behind the surface, y = c*x + (0.5 - 0.5c), so c = -1 is
                        // exactly y = 1 - x.
                        SSlider { id: gcS; from: -2; to: 2; step: 0.05
                                  value: Number(win.ts("glassContrast", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("glassContrast", v) }
                    }
                    SRow {
                        name: "Menu blur"
                        SToggle { checked: Theme.menuBlur
                                  onToggled: (v) => ThemeBackend.setThemeSetting("menuBlur", v ? "on" : "off") }
                    }
                }

                SectionHead { title: "CONTROLS"; kind: "controls" }
                Column {
                    width: col.width
                    visible: win.secOpen("controls")
                    SectionTools { title: "CONTROLS"; kind: "controls" }
                    SRow {
                        name: "View tabs"
                        SSelect { value: String(win.ts("viewTabs", "filled")); options: win.tabStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("viewTabs", v) }
                    }
                    SRow {
                        name: "Chips"
                        SSelect { value: String(win.ts("chips", "pill")); options: win.tabStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("chips", v) }
                    }
                    SRow {
                        name: "Page tabs"
                        SSelect { value: String(win.ts("pageTabs", "underline")); options: win.tabStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("pageTabs", v) }
                    }
                    SRow {
                        name: "Toggles"
                        SSelect { value: String(win.ts("toggles", "segment")); options: win.tabStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("toggles", v) }
                    }
                    SRow {
                        name: "Tab gap"
                        desc: Math.round(tabGapS.shown)
                        SSlider { id: tabGapS; from: 0; to: 16; step: 1
                                  value: Theme.tabGap
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("tabGap", Math.round(v)) }
                    }
                    SRow {
                        name: "Tab height"
                        desc: Math.round(tabHS.shown) + " px"
                        SSlider { id: tabHS; from: 16; to: 40; step: 1
                                  value: Theme.tabHeight
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("tabHeight", Math.round(v)) }
                    }
                    SRow {
                        name: "Tab track padding"
                        desc: Math.round(tabPadS.shown) + " px"
                        SSlider { id: tabPadS; from: 0; to: 12; step: 1
                                  value: Theme.tabTrackPad
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("tabTrackPad", Math.round(v)) }
                    }
                    SRow {
                        name: "Button gap"
                        desc: Math.round(btnGapS.shown)
                        SSlider { id: btnGapS; from: 0; to: 16; step: 1
                                  value: Theme.buttonGap
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("buttonGap", Math.round(v)) }
                    }
                    SRow {
                        name: "Dropdowns"
                        SSelect { value: Theme.inputSelects ? "input" : "button"
                                  options: [ { value: "button", label: "Button" }, { value: "input", label: "Text input" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("inputSelects", v === "input") }
                    }
                    SRow {
                        name: "Title bar icons"
                        SSelect { value: String(win.ts("titleButtons", "bare")); options: win.iconButtonStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("titleButtons", v) }
                    }
                    SRow {
                        name: "Page tools"
                        SSelect { value: String(win.ts("toolButtons", "bare")); options: win.iconButtonStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("toolButtons", v) }
                    }
                    SRow {
                        name: "Player buttons"
                        SSelect { value: String(win.ts("transportButtons", "bare")); options: win.iconButtonStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("transportButtons", v) }
                    }
                    SRow {
                        name: "Card art corners"
                        SSelect { value: Theme.cardArtCorners
                                  options: [ { value: "auto", label: "Auto" }, { value: "square", label: "Square" }, { value: "round", label: "Round" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("cardArtCorners", v) }
                    }
                    SRow {
                        name: "Button height"
                        desc: Math.round(btnHeightS.shown)
                        SSlider { id: btnHeightS; from: 16; to: 40; step: 1; value: Theme.buttonHeight
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("buttonHeight", Math.round(v)) }
                    }
                    SRow {
                        name: "Icon button size"
                        desc: Math.round(iconBtnSizeS.shown)
                        SSlider { id: iconBtnSizeS; from: 18; to: 44; step: 1; value: Theme.iconButtonSize
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("iconButtonSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Title bar button size"
                        desc: Number(Theme.ts.titleButtonSize) > 0 ? Math.round(titleBtnS.shown) : "same"
                        SSlider { id: titleBtnS; from: 0; to: 44; step: 1; value: Number(Theme.ts.titleButtonSize) || 0
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("titleButtonSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Glyph size"
                        desc: Math.round(gsS.shown)
                        SSlider { id: gsS; from: 8; to: 28; step: 1; value: Theme.glyphSize
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("glyphSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Button press"
                        SSelect { value: String(win.ts("buttonPress", "none")); options: win.pressStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("buttonPress", v) }
                    }
                    SRow {
                        name: "Slider track height"
                        desc: Math.round(sldTrackS.shown)
                        SSlider { id: sldTrackS; from: 1; to: 16; step: 1; value: Theme.sliderTrackHeight
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("sliderTrackHeight", Math.round(v)) }
                    }
                    SRow {
                        name: "Slider knob size"
                        desc: Math.round(sldKnobS.shown)
                        SSlider { id: sldKnobS; from: 6; to: 24; step: 1; value: Theme.sliderKnobSize
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("sliderKnobSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Slider knob"
                        SSelect { value: Theme.sliderKnobShape; options: win.knobShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("sliderKnobShape", v) }
                    }
                    SRow {
                        name: "Slider knob inset"
                        desc: Math.round(knobInS.shown)
                        SSlider { id: knobInS; from: -12; to: 24; step: 1; value: Theme.sliderKnobInset
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("sliderKnobInset", Math.round(v)) }
                    }
                    SRow {
                        name: "Slider knob aspect"
                        desc: sldAspS.shown.toFixed(2)
                        SSlider { id: sldAspS; from: 0.2; to: 3; step: 0.05; value: Theme.sliderKnobAspect
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("sliderKnobAspect", Math.round(v * 100) / 100) }
                    }
                    SRow {
                        name: "Slider track"
                        SSelect { value: Theme.sliderTrackShape; options: win.knobShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("sliderTrackShape", v) }
                    }
                    SRow {
                        name: "Scrubber"
                        SSelect { value: Theme.scrubberShape; options: win.knobShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("scrubberShape", v) }
                    }
                    SRow {
                        name: "Scrubber hover"
                        SSelect { value: Theme.scrubberGrow ? "grow" : "still"
                                  options: [ { value: "grow", label: "Grow" }, { value: "still", label: "Still" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("scrubberHover", v) }
                    }
                    SRow {
                        name: "Scrubber knob size"
                        desc: Math.round(scKnobS.shown)
                        SSlider { id: scKnobS; from: 0; to: 24; step: 1; value: Theme.scrubberKnobSize
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("scrubberKnobSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Scrubber knob"
                        SSelect { value: Theme.scrubberKnobShape; options: win.knobShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("scrubberKnobShape", v) }
                    }
                    SRow {
                        name: "Scrubber knob inset"
                        desc: Math.round(scKnobInS.shown)
                        SSlider { id: scKnobInS; from: -12; to: 24; step: 1; value: Theme.scrubberKnobInset
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("scrubberKnobInset", Math.round(v)) }
                    }
                    SRow {
                        name: "Scrubber knob aspect"
                        desc: scAspS.shown.toFixed(2)
                        SSlider { id: scAspS; from: 0.2; to: 3; step: 0.05; value: Theme.scrubberKnobAspect
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("scrubberKnobAspect", Math.round(v * 100) / 100) }
                    }
                    // The volume is its own slider, so a bar whose volume is a
                    // fader does not put that fader on every slider in the app.
                    // Each of these follows the slider until it is set.
                    SRow {
                        name: "Volume track height"
                        desc: volTrackS.shown < 1 ? "Slider" : Math.round(volTrackS.shown)
                        SSlider { id: volTrackS; from: 0; to: 16; step: 1; value: win.ts("volumeTrackHeight", 0)
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("volumeTrackHeight", Math.round(v)) }
                    }
                    SRow {
                        name: "Volume knob size"
                        desc: volKnobS.shown < 1 ? "Slider" : Math.round(volKnobS.shown)
                        SSlider { id: volKnobS; from: 0; to: 32; step: 1; value: win.ts("volumeKnobSize", 0)
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("volumeKnobSize", Math.round(v)) }
                    }
                    SRow {
                        name: "Volume knob aspect"
                        desc: volAspS.shown < 0.05 ? "Slider" : volAspS.shown.toFixed(2)
                        SSlider { id: volAspS; from: 0; to: 3; step: 0.05; value: win.ts("volumeKnobAspect", 0)
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("volumeKnobAspect", Math.round(v * 100) / 100) }
                    }
                    SRow {
                        name: "Volume knob"
                        SSelect { value: String(win.ts("volumeKnobShape", "")); options: win.volumeShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("volumeKnobShape", v) }
                    }
                    SRow {
                        name: "Volume knob inset"
                        desc: volInS.shown < 0 ? "Slider" : Math.round(volInS.shown)
                        SSlider { id: volInS; from: -1; to: 24; step: 1; value: win.ts("volumeKnobInset", -1)
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("volumeKnobInset", Math.round(v)) }
                    }
                    SRow {
                        name: "Volume track"
                        SSelect { value: String(win.ts("volumeTrackShape", "")); options: win.volumeShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("volumeTrackShape", v) }
                    }
                    SRow {
                        name: "Skeleton"
                        SSelect { value: Theme.skeletonStyle; options: win.skeletonStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("skeletonStyle", v) }
                    }
                    SRow {
                        name: "Scrollbars"
                        SSelect { value: Theme.scrollbars; options: win.scrollbarStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("scrollbars", v) }
                    }
                    SRow {
                        name: "Scrollbar width"
                        desc: sbWidthS.shown < 1 ? "Style" : Math.round(sbWidthS.shown)
                        SSlider { id: sbWidthS; from: 0; to: 32; step: 1; value: win.ts("scrollbarWidth", 0)
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("scrollbarWidth", Math.round(v)) }
                    }
                    SRow {
                        name: "Scrollbar grip"
                        SSelect { value: Theme.scrollbarGrip; options: win.gripStyles
                                  onPicked: (v) => ThemeBackend.setThemeSetting("scrollbarGrip", v) }
                    }
                    SRow {
                        name: "Toggle width"
                        desc: Math.round(togWidthS.shown)
                        SSlider { id: togWidthS; from: 20; to: 72; step: 1; value: Theme.toggleWidth
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("toggleWidth", Math.round(v)) }
                    }
                    SRow {
                        name: "Toggle height"
                        desc: Math.round(togHeightS.shown)
                        SSlider { id: togHeightS; from: 12; to: 40; step: 1; value: Theme.toggleHeight
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("toggleHeight", Math.round(v)) }
                    }
                    SRow {
                        name: "Toggle knob"
                        SSelect { value: Theme.toggleKnobShape; options: win.knobShapes
                                  onPicked: (v) => ThemeBackend.setThemeSetting("toggleKnobShape", v) }
                    }
                }

                SectionHead { title: "GLYPHS"; kind: "glyphs" }
                Column {
                    width: col.width
                    visible: win.secOpen("glyphs")
                    SectionTools { title: "GLYPHS"; kind: "glyphs" }
                    Repeater {
                        model: Theme.glyphNames
                        SRow {
                            id: glyphRow
                            required property string modelData
                            name: modelData
                            desc: win.glyphError[modelData] || ""
                            reserve: Theme.sp(220)
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(8)
                                Icon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: glyphRow.modelData; ink: "text"; size: Theme.ctl(18)
                                }
                                SBtn {
                                    label: "Import"
                                    onClicked: {
                                        win.glyphFor = glyphRow.modelData
                                        Portal.openFile("glyph-import", "Import glyph", "SVG", ["*.svg"], false)
                                    }
                                }
                                SBtn {
                                    label: "Reset"
                                    visible: Theme.glyphMap[glyphRow.modelData] !== undefined
                                    onClicked: win.setGlyph(glyphRow.modelData, undefined)
                                }
                            }
                        }
                    }
                }

                SectionHead { title: "INSETS"; kind: "insets" }
                Column {
                    width: col.width
                    visible: win.secOpen("insets")
                    SectionTools { title: "INSETS"; kind: "insets" }
                    Repeater {
                        model: Theme.insetNames
                        SRow {
                            id: insRow
                            required property string modelData
                            name: win.insetLabels[modelData] || modelData
                            reserve: Theme.sp(200)
                            Row {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(4)
                                Repeater {
                                    model: Theme.insetSides
                                    Surface {
                                        required property string modelData
                                        readonly property real held: (Theme.ts, Theme.insetOf(insRow.modelData, modelData))
                                        width: Theme.sp(44); height: Theme.sp(24)
                                        radius: Theme.radiusMd
                                        role: "input"
                                        borderWidth: 1
                                        borderRole: insIn.activeFocus ? "borderStrong" : "border"
                                        InkText { x: Theme.gap(5); anchors.verticalCenter: parent.verticalCenter
                                                  text: parent.modelData[0].toUpperCase(); ink: "textFaint"
                                                  font { pixelSize: Theme.fs(9); family: Theme.fontFamily } }
                                        TextInput {
                                            id: insIn
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.gap(14); anchors.rightMargin: Theme.gap(4)
                                            verticalAlignment: TextInput.AlignVCenter
                                            horizontalAlignment: TextInput.AlignRight
                                            color: Theme.text
                                            validator: IntValidator { bottom: -64; top: 64 }
                                            font { pixelSize: Theme.fs(11); family: "monospace" }
                                            text: activeFocus ? text : String(parent.held)
                                            onEditingFinished: win.setInset(insRow.modelData, parent.modelData, text)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                SectionHead { title: "PLAYER"; kind: "player" }
                Column {
                    width: col.width
                    visible: win.secOpen("player")
                    SectionTools { title: "PLAYER"; kind: "player" }
                    SRow {
                        name: "Player bar"
                        SSelect { value: String(win.ts("barMain", "rows")); options: win.barKinds; note: win.slotNote("barMain")
                                  onPicked: (v) => { ThemeBackend.clearLayoutOverride("barMain"); ThemeBackend.setThemeSetting("barMain", v) } }
                    }
                    SRow {
                        name: "Player bar, now playing"
                        SSelect { value: String(win.ts("barNp", "centre")); options: win.barKinds; note: win.slotNote("barNp")
                                  onPicked: (v) => { ThemeBackend.clearLayoutOverride("barNp"); ThemeBackend.setThemeSetting("barNp", v) } }
                    }
                    SRow {
                        name: "Player bar, mini player"
                        SSelect { value: String(win.ts("barMini", "rows")); options: win.barKinds; note: win.slotNote("barMini")
                                  onPicked: (v) => { ThemeBackend.clearLayoutOverride("barMini"); ThemeBackend.setThemeSetting("barMini", v) } }
                    }
                    SRow {
                        name: "Backing"
                        SSelect { value: String(win.ts("backMain", "surface")); options: win.backKinds
                                  onPicked: (v) => ThemeBackend.setThemeSetting("backMain", v) }
                    }
                    SRow {
                        name: "Backing, now playing"
                        SSelect { value: String(win.ts("backNp", "none")); options: win.backKinds
                                  onPicked: (v) => ThemeBackend.setThemeSetting("backNp", v) }
                    }
                    SRow {
                        name: "Backing, mini player"
                        SSelect { value: String(win.ts("backMini", "surface")); options: win.backKinds
                                  onPicked: (v) => ThemeBackend.setThemeSetting("backMini", v) }
                    }
                    SRow {
                        name: "Floating inset"
                        desc: Math.round(fiS.shown) + " px"
                        SSlider { id: fiS; from: 0; to: 24; step: 1
                                  value: Number(win.ts("floatInset", 10))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("floatInset", Math.round(v)) }
                    }
                    SRow {
                        name: "Floating offset"
                        desc: Math.round(foS.shown) + " px"
                        SSlider { id: foS; from: -12; to: 12; step: 1
                                  value: Number(win.ts("floatOffset", 0))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("floatOffset", Math.round(v)) }
                    }
                    SRow {
                        name: "Bar transition"
                        SSelect { value: String(win.ts("barTransition", "rise"))
                                  options: [ { value: "rise", label: "Rise" }, { value: "drop", label: "Drop" },
                                             { value: "height", label: "By height" },
                                             { value: "slide", label: "Slide" }, { value: "zoom", label: "Zoom" },
                                             { value: "fade", label: "Fade" }, { value: "blur", label: "Blur" },
                                             { value: "none", label: "None" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("barTransition", v) }
                    }
                    SRow {
                        name: "Transition speed"
                        desc: tsS.shown <= 0 ? "Instant" : Math.round(tsS.shown) + " ms"
                        SSlider { id: tsS; from: 0; to: 800; step: 20
                                  value: Number(win.ts("barSwapMs", 300))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("barSwapMs", Math.round(v)) }
                    }
                    SRow {
                        name: "Bar resize"
                        SSelect { value: String(win.ts("barResize", "ease"))
                                  options: [ { value: "ease", label: "Ease" }, { value: "spring", label: "Spring" }, { value: "snap", label: "Snap" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("barResize", v) }
                    }
                    SRow {
                        name: "Centre scrub bar"
                        SSelect { value: String(win.ts("centreScrub", "auto"))
                                  options: [ { value: "auto", label: "Auto" }, { value: "under", label: "Under the controls" },
                                             { value: "edge", label: "Window edge" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("centreScrub", v) }
                    }
                }
                Column {
                    width: col.width
                    visible: win.secOpen("player")
                    // arrange, on the bar itself in the main window
                    SRow {
                        name: "Arrange"
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(6)
                            SBtn { label: "Main"; onClicked: win.arrange("barMain") }
                            SBtn { label: "Now playing"; onClicked: win.arrange("barNp") }
                            SBtn { label: "Mini player"; onClicked: win.arrange("barMini") }
                        }
                    }
                }
                SectionHead { title: "BEHAVIOUR"; kind: "behaviour" }
                Column {
                    width: col.width
                    visible: win.secOpen("behaviour")
                    SectionTools { title: "BEHAVIOUR"; kind: "behaviour" }
                    SRow {
                        name: "Window fade"
                        SSelect { value: String(win.ts("fadeMode", "off"))
                                  options: [ { value: "off", label: "Off" },
                                             { value: "hover", label: "When the mouse leaves melo" },
                                             { value: "focus", label: "When you switch to another window" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("fadeMode", v) }
                    }
                    SRow {
                        visible: String(win.ts("fadeMode", "off")) !== "off"
                        name: "Faded opacity"
                        desc: Math.round(hoS.shown * 100) + "%"
                        SSlider { id: hoS; from: 0.1; to: 1; step: 0.05
                                  value: Number(win.ts("hoverOpacity", 0.3))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("hoverOpacity", v) }
                    }
                    SRow {
                        name: "Window fade (mini player)"
                        SSelect { value: String(win.ts("miniFadeMode", "off"))
                                  options: [ { value: "off", label: "Off" },
                                             { value: "hover", label: "When the mouse leaves melo" },
                                             { value: "focus", label: "When you switch to another window" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("miniFadeMode", v) }
                    }
                    SRow {
                        visible: String(win.ts("miniFadeMode", "off")) !== "off"
                        name: "Faded opacity (mini player)"
                        desc: Math.round(mhoS.shown * 100) + "%"
                        SSlider { id: mhoS; from: 0.1; to: 1; step: 0.05
                                  value: Number(win.ts("miniHoverOpacity", 0.3))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("miniHoverOpacity", v) }
                    }
                    SRow {
                        visible: String(win.ts("glassBlur", "off")) === "hover"
                                 || String(win.ts("fadeMode", "off")) === "hover"
                        name: "Hover linger"
                        desc: Math.round(bdS.shown) + "ms"
                        SSlider { id: bdS; from: 0; to: 2000; step: 100
                                  value: Number(win.ts("glassHoverDelay", 0))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("glassHoverDelay", Math.round(v)) }
                    }
                    SRow {
                        visible: String(win.ts("glassBlur", "off")) === "hover"
                                 || String(win.ts("fadeMode", "off")) !== "off"
                                 || String(win.ts("miniFadeMode", "off")) !== "off"
                        name: "Hover fade speed"
                        desc: Math.round(hfS.shown) + "ms"
                        SSlider { id: hfS; from: 0; to: 1000; step: 20
                                  value: Number(win.ts("hoverFadeMs", 180))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("hoverFadeMs", Math.round(v)) }
                    }
                }

                SectionHead { title: "SIZE"; kind: "size" }
                Column {
                    width: col.width
                    visible: win.secOpen("size")
                    SectionTools { title: "SIZE"; kind: "size" }
                    SRow {
                        name: "Interface size"
                        desc: "\u00d7" + uiS.shown.toFixed(2)
                        SSlider { id: uiS; from: 0.8; to: 1.6; step: 0.05
                                  value: Number(win.ts("uiScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("uiScale", v) }
                    }
                    SRow {
                        name: "Spacing"
                        desc: "\u00d7" + spcS.shown.toFixed(2)
                        SSlider { id: spcS; from: 0.6; to: 1.8; step: 0.05
                                  value: Number(win.ts("spacingScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("spacingScale", v) }
                    }
                    SRow {
                        name: "Controls"
                        desc: "\u00d7" + ctlS.shown.toFixed(2)
                        SSlider { id: ctlS; from: 0.6; to: 1.8; step: 0.05
                                  value: Number(win.ts("controlScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("controlScale", v) }
                    }
                    SRow {
                        name: "Artwork"
                        desc: "\u00d7" + artS.shown.toFixed(2)
                        SSlider { id: artS; from: 0.6; to: 1.8; step: 0.05
                                  value: Number(win.ts("artScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("artScale", v) }
                    }
                    SRow {
                        name: "Player bar"
                        desc: "\u00d7" + barS.shown.toFixed(2)
                        SSlider { id: barS; from: 0.6; to: 1.8; step: 0.05
                                  value: Number(win.ts("barScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("barScale", v) }
                    }
                    SRow {
                        name: "Font size"
                        desc: "×" + fsS.shown.toFixed(2)
                        SSlider { id: fsS; from: 0.8; to: 1.4; step: 0.05
                                  value: Number(win.ts("fontScale", 1))
                                  onCommitted: (v) => ThemeBackend.setThemeSetting("fontScale", v) }
                    }
                }

                SectionHead { title: "BACKGROUND"; kind: "background" }
                Column {
                    width: col.width
                    visible: win.secOpen("background")
                    SectionTools { title: "BACKGROUND"; kind: "background" }
                    SRow {
                        id: bgTypeRow
                        name: "Background"
                        // options shared across types with different slider
                        // ranges: on a type switch, carry the value over at the
                        // same RELATIVE position (50/100 in a 0-100 range becomes
                        // 100/200 in a 0-200 range), so nothing lands out of range
                        readonly property var optRanges: ({
                            count:     { bokeh: [5, 40], particles: [20, 200], starfield: [50, 400] },
                            sizeRange: { bokeh: [20, 150], starfield: [1, 6] },
                            size:      { bokeh: [5, 80], particles: [1, 6], starfield: [0.5, 4] }
                        })
                        function remapOpts(oldType, newType) {
                            const r = optRanges
                            const patch = {}
                            let any = false
                            for (const key in r) {
                                const ro = r[key][oldType], rn = r[key][newType]
                                if (!ro || !rn) continue
                                const cur = Number(win.bgOpt(key, NaN))
                                if (isNaN(cur)) continue
                                const frac = Math.max(0, Math.min(1, (cur - ro[0]) / (ro[1] - ro[0])))
                                let v = rn[0] + frac * (rn[1] - rn[0])
                                v = key === "count" ? Math.round(v) : Math.round(v * 100) / 100
                                if (v !== cur) { patch[key] = v; any = true }
                            }
                            if (any) win.setBgOpt(patch)
                        }
                        SSelect { value: String(win.bg("type", "none"))
                                  options: [ { value: "none", label: "None" },
                                             { value: "gradient", label: "Gradient" },
                                             { value: "orbs", label: "Orbs" },
                                             { value: "waves", label: "Waves" },
                                             { value: "aurora", label: "Aurora" },
                                             { value: "mesh", label: "Mesh" },
                                             { value: "bokeh", label: "Bokeh" },
                                             { value: "particles", label: "Particles" },
                                             { value: "starfield", label: "Starfield" },
                                             { value: "vis-bars", label: "Visualizer: Bars" },
                                             { value: "vis-radial", label: "Visualizer: Radial" },
                                             { value: "vis-oscilloscope", label: "Visualizer: Oscilloscope" },
                                             { value: "image", label: "Image" } ]
                                  onPicked: (v) => {
                                      const old = win.bg("type", "none")
                                      win.setBg({ type: v })
                                      bgTypeRow.remapOpts(old, v)
                                  } }
                    }
                    SRow {
                        visible: ["vis-bars","vis-radial"].indexOf(win.bg("type","none")) >= 0
                        name: "Sensitivity"
                        desc: (Math.round(visSenS.shown * 10) / 10) + "×"
                        SSlider { id: visSenS; from: 0.3; to: 3; step: 0.1
                                  value: Number(win.bgOpt("sensitivity", 1))
                                  onCommitted: (v) => win.setBgOpt({ sensitivity: Math.round(v * 10) / 10 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "vis-radial"
                        name: "Rainbow"
                        SToggle { checked: win.bgOpt("rainbow", false) === true
                                  onToggled: (v) => win.setBgOpt({ rainbow: v }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "vis-oscilloscope"
                        name: "Line color"
                        SSwatch { value: String(win.bgOpt("color", "#4a9eff"))
                                  onPicked: (c) => win.setBgOpt({ color: String(c) }) }
                    }
                    SRow {
                        visible: ["aurora","mesh","bokeh"].indexOf(win.bg("type","none")) >= 0
                        name: "Colors"
                        // Click a chip to change it, right-click to remove, +
                        // to add.
                        reserve: 150
                        SSwatchList { csv: String(win.bgOpt("colors", "#cc3333,#4a9eff,#4daa5c,#e06088"))
                                      onChanged: (v) => win.setBgOpt({ colors: v }) }
                    }
                    SRow {
                        visible: ["aurora","mesh","bokeh","particles"].indexOf(win.bg("type","none")) >= 0
                        name: "Speed"
                        desc: (Math.round(bgspS.shown * 10) / 10) + "×"
                        SSlider { id: bgspS; from: 0.1; to: 3; step: 0.1
                                  value: Number(win.bgOpt("speed", 1))
                                  onCommitted: (v) => win.setBgOpt({ speed: Math.round(v * 10) / 10 }) }
                    }
                    SRow {
                        visible: ["bokeh","particles","starfield"].indexOf(win.bg("type","none")) >= 0
                        name: "Count"
                        desc: {
                            const set = Math.round(bgcnS.shown)
                            const mode = String(win.bgOpt("scaleMode", "classic"))
                            if (mode === "size" || mode === "off") return set + ""
                            const eff = Math.max(1, Math.round(set * Math.sqrt(win.mainAreaRatio)))
                            return eff === set ? set + "" : set + " → " + eff + " drawn"
                        }
                        SSlider { id: bgcnS
                                  from: win.bg("type","none") === "starfield" ? 50 : (win.bg("type","none")==="particles"?20:5)
                                  to: win.bg("type","none") === "starfield" ? 400 : (win.bg("type","none")==="particles"?200:40)
                                  step: win.bg("type","none") === "starfield" ? 10 : 1
                                  value: Number(win.bgOpt("count", win.bg("type","none")==="starfield"?200:(win.bg("type","none")==="particles"?80:15)))
                                  onCommitted: (v) => win.setBgOpt({ count: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "aurora"
                        name: "Bands"
                        desc: Math.round(bgbandS.shown) + ""
                        SSlider { id: bgbandS; from: 2; to: 8; step: 1
                                  value: Number(win.bgOpt("bands", 4))
                                  onCommitted: (v) => win.setBgOpt({ bands: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "aurora"
                        name: "Intensity"
                        desc: (Math.round(bgintS.shown * 100) / 100) + ""
                        SSlider { id: bgintS; from: 0.1; to: 1.5; step: 0.05
                                  value: Number(win.bgOpt("intensity", 0.6))
                                  onCommitted: (v) => win.setBgOpt({ intensity: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "mesh"
                        name: "Blob size"
                        desc: (Math.round(bgblobS.shown * 100) / 100) + ""
                        SSlider { id: bgblobS; from: 0.2; to: 1.2; step: 0.05
                                  value: Number(win.bgOpt("blobSize", 0.6))
                                  onCommitted: (v) => win.setBgOpt({ blobSize: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: ["bokeh","starfield"].indexOf(win.bg("type","none")) >= 0
                        name: "Base size"
                        desc: (Math.round(bgbszS.shown * 10) / 10) + " px"
                        SSlider { id: bgbszS
                                  from: win.bg("type","none") === "starfield" ? 0.5 : 5
                                  to: win.bg("type","none") === "starfield" ? 4 : 80
                                  step: win.bg("type","none") === "starfield" ? 0.25 : 5
                                  value: Number(win.bgOpt("size", win.bg("type","none")==="starfield"?0.5:20))
                                  onCommitted: (v) => win.setBgOpt({ size: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: ["bokeh","starfield"].indexOf(win.bg("type","none")) >= 0
                        name: "Size range"
                        desc: (Math.round(bgsrS.shown * 10) / 10) + " px"
                        SSlider { id: bgsrS
                                  from: win.bg("type","none") === "starfield" ? 1 : 20
                                  to: win.bg("type","none") === "starfield" ? 6 : 150
                                  step: win.bg("type","none") === "starfield" ? 0.5 : 5
                                  value: Number(win.bgOpt("sizeRange", win.bg("type","none")==="starfield"?2:60))
                                  onCommitted: (v) => win.setBgOpt({ sizeRange: Math.round(v * 10) / 10 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "particles"
                        name: "Particle size"
                        desc: (Math.round(bgpszS.shown * 10) / 10) + " px"
                        SSlider { id: bgpszS; from: 1; to: 6; step: 0.5
                                  value: Number(win.bgOpt("size", 2))
                                  onCommitted: (v) => win.setBgOpt({ size: Math.round(v * 10) / 10 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "particles"
                        name: "Connect lines"
                        SToggle { checked: win.bgOpt("lines", true) !== false
                                  onToggled: (v) => win.setBgOpt({ lines: v }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "particles" && win.bgOpt("lines", true) !== false
                        name: "Line distance"
                        desc: Math.round(bgldS.shown) + " px"
                        SSlider { id: bgldS; from: 40; to: 300; step: 10
                                  value: Number(win.bgOpt("lineDistance", 120))
                                  onCommitted: (v) => win.setBgOpt({ lineDistance: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "starfield"
                        name: "Twinkle"
                        SToggle { checked: win.bgOpt("twinkle", true) !== false
                                  onToggled: (v) => win.setBgOpt({ twinkle: v }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "starfield"
                        name: "Drift"
                        desc: (Math.round(bgdriftS.shown * 100) / 100) + ""
                        SSlider { id: bgdriftS; from: 0; to: 1; step: 0.05
                                  value: Number(win.bgOpt("drift", 0.1))
                                  onCommitted: (v) => win.setBgOpt({ drift: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") === "starfield"
                        name: "Colored stars"
                        SToggle { checked: win.bgOpt("colored", false) === true
                                  onToggled: (v) => win.setBgOpt({ colored: v }) }
                    }
                    SRow {
                        visible: ["orbs","bokeh","particles","starfield"].indexOf(win.bg("type","none")) >= 0
                        name: "Resolution scaling"
                        SSelect { value: String(win.bgOpt("scaleMode", "classic"))
                                  options: [ { value: "classic", label: "Size + count" },
                                             { value: "count", label: "Count" },
                                             { value: "size", label: "Size" },
                                             { value: "off", label: "Off" } ]
                                  onPicked: (v) => win.setBgOpt({ scaleMode: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none"
                        name: "Background opacity"
                        desc: Math.round((bgoS.shown) * 100) + "%"
                        SSlider { id: bgoS; from: 0; to: 1; step: 0.05
                                  value: Number(win.bg("opacity", 1))
                                  onCommitted: (v) => win.setBg({ opacity: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none"
                        name: "Zoom"
                        desc: (Math.round(bgScaleS.shown * 100) / 100) + "×"
                        SSlider { id: bgScaleS; from: 0.5; to: 3; step: 0.05
                                  value: Number(win.bg("scale", 1))
                                  onCommitted: (v) => win.setBg({ scale: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none"
                        name: "Position X"
                        desc: Math.round(bgPxS.shown * 100) + "%"
                        SSlider { id: bgPxS; from: -0.5; to: 0.5; step: 0.01
                                  value: Number(win.bg("positionX", 0))
                                  onCommitted: (v) => win.setBg({ positionX: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none"
                        name: "Position Y"
                        desc: Math.round(bgPyS.shown * 100) + "%"
                        SSlider { id: bgPyS; from: -0.5; to: 0.5; step: 0.01
                                  value: Number(win.bg("positionY", 0))
                                  onCommitted: (v) => win.setBg({ positionY: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none"
                        name: "Show in mini player"
                        SToggle { checked: win.bg("showInMini", true) !== false
                                  onToggled: (v) => win.setBg({ showInMini: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none" && win.bg("showInMini", true) !== false
                        name: "Preserve size in mini"
                        SToggle { checked: win.bg("preserveInMini", false) === true
                                  onToggled: (v) => win.setBg({ preserveInMini: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") !== "none" && win.bg("showInMini", true) !== false
                        name: "Separate mini zoom/position"
                        SToggle { checked: win.bg("perModePosition", false) === true
                                  onToggled: (v) => win.setBg({ perModePosition: v }) }
                    }
                    SRow {
                        visible: win.bg("type","none") !== "none" && win.bg("showInMini", true) !== false
                                 && win.bg("perModePosition", false) === true
                        name: "Mini zoom"
                        desc: (Math.round(bgmScaleS.shown * 100) / 100) + "×"
                        SSlider { id: bgmScaleS; from: 0.5; to: 3; step: 0.05
                                  value: Number(win.bg("miniScale", 1))
                                  onCommitted: (v) => win.setBg({ miniScale: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") !== "none" && win.bg("showInMini", true) !== false
                                 && win.bg("perModePosition", false) === true
                        name: "Mini position X"
                        desc: Math.round(bgmPxS.shown * 100) + "%"
                        SSlider { id: bgmPxS; from: -0.5; to: 0.5; step: 0.01
                                  value: Number(win.bg("miniPositionX", 0))
                                  onCommitted: (v) => win.setBg({ miniPositionX: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type","none") !== "none" && win.bg("showInMini", true) !== false
                                 && win.bg("perModePosition", false) === true
                        name: "Mini position Y"
                        desc: Math.round(bgmPyS.shown * 100) + "%"
                        SSlider { id: bgmPyS; from: -0.5; to: 0.5; step: 0.01
                                  value: Number(win.bg("miniPositionY", 0))
                                  onCommitted: (v) => win.setBg({ miniPositionY: Math.round(v * 100) / 100 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "image"
                        name: "Background blur"
                        // No "px": the effect scales with the background's
                        // rendered size, so the number is an amount rather than
                        // a distance.
                        desc: Math.round(bgbS.shown) === 0 ? "None" : String(Math.round(bgbS.shown))
                        // 0-100. At 1080p that is a 100px radius: MultiEffect
                        // to 64, then Kawase, which reaches it at depth 4 with
                        // the sample offset at 2.2 — mid-band, not against a
                        // clamp. At 4K the same setting is 200px, depth 5.
                        SSlider { id: bgbS; from: 0; to: 100; step: 1
                                  value: Number(win.bg("blur", 0))
                                  onCommitted: (v) => win.setBg({ blur: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "image"
                        name: "Image file"
                        desc: String(win.bg("src", "")).split("/").pop()
                        SBtn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                               label: "Choose…"
                               onClicked: bgFileDialog.open() }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "image"
                        name: "Image fit"
                        SSelect { value: String(win.bg("size", "cover"))
          options: [ { value: "cover", label: "Fill (cover)" },
                                             { value: "contain", label: "Fit (contain)" },
                                             { value: "stretch", label: "Stretch" } ]
                                  onPicked: (v) => win.setBg({ size: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "image"
                                 && String(win.bg("src", "")).length > 0
                                 && win.bg("size", "cover") !== "stretch"
                        name: "Crop toward"
                        desc: Math.round(Number(win.bg("cropX", 0.5)) * 100) + "%, "
                              + Math.round(Number(win.bg("cropY", 0.5)) * 100) + "%"
                        reserve: 210
                        SCropPick {
                            src: String(win.bg("src", ""))
                            px: Number(win.bg("cropX", 0.5))
                            py: Number(win.bg("cropY", 0.5))
                            onPicked: (x, y) => win.setBg({ cropX: Math.round(x * 100) / 100,
                                                            cropY: Math.round(y * 100) / 100 })
                        }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "gradient"
                        name: "Gradient"
                        reserve: 160
                        SGradient { css: String(win.bg("gradient", "linear-gradient(180deg, #12203a 0%, #0a0f1a 100%)"))
                                    onChanged: (v) => win.setBg({ gradient: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "gradient"
                        name: "Direction"
                        // Two options because BackgroundLayer snaps every angle
                        // to one of them; a dial would offer what melo does not do.
                        SSelect {
                            options: [ { value: "180", label: "Vertical" },
                                       { value: "90",  label: "Horizontal" } ]
                            value: win.gradientIsHorizontal(String(win.bg("gradient", ""))) ? "90" : "180"
                            onPicked: (v) => {
                                const cur = String(win.bg("gradient", "linear-gradient(180deg, #12203a 0%, #0a0f1a 100%)"))
                                win.setBg({ gradient: /deg/.test(cur)
                                    ? cur.replace(/-?[\d.]+deg/, v + "deg")
                                    : cur.replace(/linear-gradient\(/i, "linear-gradient(" + v + "deg, ") })
                            }
                        }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "orbs"
                        name: "Orb count"
                        desc: {
                            const set = Math.round(orbcS.shown)
                            const mode = String(win.bgOpt("scaleMode", "classic"))
                            if (mode === "size" || mode === "off") return set + " orbs"
                            const eff = Math.max(1, Math.round(set * Math.sqrt(win.mainAreaRatio)))
                            return eff === set ? set + " orbs" : set + " → " + eff + " drawn"
                        }
                        SSlider { id: orbcS; from: 3; to: 20; step: 1
                                  value: Number(win.bgOpt("count", 8))
                                  onCommitted: (v) => win.setBgOpt({ count: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "orbs"
                        name: "Orb speed"
                        desc: (Math.round(orbsS.shown * 10) / 10) + "×"
                        SSlider { id: orbsS; from: 0.1; to: 3; step: 0.1
                                  value: Number(win.bgOpt("speed", 1))
                                  onCommitted: (v) => win.setBgOpt({ speed: Math.round(v * 10) / 10 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "orbs"
                        name: "Orb min size"
                        desc: Math.round(orbnS.shown) + "px"
                        SSlider { id: orbnS; from: 20; to: 200; step: 10
                                  value: Number(win.bgOpt("minSize", 60))
                                  onCommitted: (v) => win.setBgOpt({ minSize: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "orbs"
                        name: "Orb max size"
                        desc: Math.round(orbxS.shown) + "px"
                        SSlider { id: orbxS; from: 50; to: 400; step: 10
                                  value: Number(win.bgOpt("maxSize", 200))
                                  onCommitted: (v) => win.setBgOpt({ maxSize: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "orbs"
                        name: "Orb colors"
                        reserve: 150
                        SSwatchList { csv: String(win.bgOpt("colors", "#cc3333,#4a9eff,#4daa5c,#e06088"))
                                      onChanged: (v) => win.setBgOpt({ colors: v }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "waves"
                        name: "Wave layers"
                        desc: Math.round(wvlS.shown) + ""
                        SSlider { id: wvlS; from: 1; to: 8; step: 1
                                  value: Number(win.bgOpt("layers", 4))
                                  onCommitted: (v) => win.setBgOpt({ layers: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "waves"
                        name: "Wave height"
                        desc: Math.round(wvaS.shown) + "px"
                        SSlider { id: wvaS; from: 10; to: 150; step: 5
                                  value: Number(win.bgOpt("amplitude", 60))
                                  onCommitted: (v) => win.setBgOpt({ amplitude: Math.round(v) }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "waves"
                        name: "Wave speed"
                        desc: (Math.round(wvsS.shown * 10) / 10) + "×"
                        SSlider { id: wvsS; from: 0.1; to: 3; step: 0.1
                                  value: Number(win.bgOpt("speed", 1))
                                  onCommitted: (v) => win.setBgOpt({ speed: Math.round(v * 10) / 10 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "waves"
                        name: "Wave position"
                        desc: Math.round(wvpS.shown * 100) + "%"
                        SSlider { id: wvpS; from: 0.2; to: 0.95; step: 0.05
                                  value: Number(win.bgOpt("position", 0.7))
                                  onCommitted: (v) => win.setBgOpt({ position: Math.round(v * 20) / 20 }) }
                    }
                    SRow {
                        visible: win.bg("type", "none") === "waves"
                        name: "Wave colors"
                        reserve: 150
                        SSwatchList { csv: String(win.bgOpt("colors", "#cc3333,#4a9eff,#4daa5c"))
                                      onChanged: (v) => win.setBgOpt({ colors: v }) }
                    }
                    SRow {
                        name: "Visualizer background"
                        SSelect { value: String(win.ts("visualizerBg", "solid"))
                                  options: [ { value: "solid", label: "Solid" },
                                             { value: "transparent", label: "Transparent" } ]
                                  onPicked: (v) => ThemeBackend.setThemeSetting("visualizerBg", v) }
                    }
                }
                }

            }

            // ============ SHORTCUTS ============
            Column {

                visible: win.tab === "shortcuts"
                width: col.width

                Repeater {
                    model: win.shortcutRows
                    ShortcutRow { required property var modelData; row: modelData }
                }

                Item {
                    width: col.width; height: 34
                    SBtn {
                        anchors.right: parent.right; anchors.rightMargin: Theme.gap(16)
                        anchors.verticalCenter: parent.verticalCenter
                        label: "Reset all"
                        onClicked: {
                            win.shortcuts = SC.merged(null)
                            Settings.uiSet("shortcuts", win.shortcuts)
                            const g = {}
                            for (let i = 0; i < CMD.GESTURES.length; i++) {
                                const gid = CMD.GESTURES[i]
                                g[gid] = CMD.GESTURE_DEFAULTS[gid]
                            }
                            win.gestures = g
                            Settings.uiSet("gestures", g)
                        }
                    }
                }
            }

            // ============ PLUGINS ============
            Column {
                visible: win.tab === "plugins" && win.pluginSettingsFor.length === 0
                width: col.width

                // always-available actions: drop a folder in, Rescan (no app
                // restart), then enable — Open folder works whether or not
                // plugins already exist
                SRow {
                    name: win.pluginList.length === 0 ? "No plugins installed" : "Plugins"
                    desc: win.pluginList.length === 0 ? "No plugins" : ""
                    SBtn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                           label: "Open folder"
                           onClicked: Qt.openUrlExternally("file://" + Settings.dataDir + "/plugins") }
                }
                Repeater {
                    model: win.tab === "plugins" ? win.pluginList : []
                    Column {
                        id: pluginBlock
                        width: col.width
                        required property var modelData
                        readonly property bool warned: (modelData.warnings || []).length > 0
                        // No in-flight lock here: the delegate is rebuilt on every pluginsChanged
                        // (JS array model), so a row-local busy flag would be cleared by another
                        // plugin's refresh. Partial patches make concurrent clicks safe; see
                        // plugingrants.js.

                        SRow {
                            id: pluginRow
                            // enabling a WARNED plugin doesn't flip immediately —
                            // it reveals an explicit "Enable anyway" button (clearer
                            // than a re-click); the toggle stays bound to enabled.
                            // Enable anyway grants ui for a ui plugin (sidecar).
                            property bool confirming: false
                            reserve: 100 + (pluginRow.confirming ? 150 : 0)
                                         + ((pluginBlock.modelData.settings || []).length > 0 ? 42 : 0)
                            name: pluginBlock.modelData.name + "  " + pluginBlock.modelData.version
                                 + (win.pluginStatus(pluginBlock.modelData).length > 0
                                    ? "  " + win.pluginStatus(pluginBlock.modelData) : "")
                            desc: (pluginBlock.modelData.description || "")
                                 + win.pluginNetworkDesc(pluginBlock.modelData)
                                 + (pluginBlock.warned
                                    ? "\n⚠ " + pluginBlock.modelData.warnings.join("\n⚠ ") : "")
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.gap(8)
                                // shown only after you try to enable a warned plugin
                                SBtn {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: pluginRow.confirming
                                    label: "Enable anyway"; danger: true
                                    onClicked: {
                                        pluginRow.confirming = false
                                        sidecar.setPluginEnabled(pluginBlock.modelData.id, true)
                                    }
                                }
                                SBtn {
                                    anchors.verticalCenter: parent.verticalCenter
                                    // Only for an enabled plugin: the manifest schema is read at
                                    // discovery either way, but settings for something not running
                                    // configure nothing visible.
                                    visible: pluginBlock.modelData.enabled
                                             && (pluginBlock.modelData.settings || []).length > 0
                                    label: "⚙"
                                    onClicked: win.openPluginSettings(pluginBlock.modelData.id)
                                }
                                SToggle {
                                    anchors.right: undefined; anchors.verticalCenter: undefined
                                    enabled: PG.enableToggleEnabled(pluginBlock.modelData)
                                    checked: pluginBlock.modelData.enabled
                                    onToggled: (v) => {
                                        if (v && pluginBlock.warned && !pluginBlock.modelData.enabled) {
                                            pluginRow.confirming = true   // needs the explicit button
                                            return
                                        }
                                        pluginRow.confirming = false
                                        sidecar.setPluginEnabled(pluginBlock.modelData.id, v)
                                    }
                                }
                            }
                        }
                        Repeater {
                            model: PG.rows(pluginBlock.modelData)
                            SRow {
                                id: grantRow
                                required property var modelData
                                readonly property bool needsConfirm: modelData.kind === "ui"
                                                                  || modelData.kind === "rawNetwork"
                                property bool confirming: false
                                reserve: 100 + (grantRow.confirming ? 170 : 0)
                                name: modelData.name
                                desc: PG.warning(pluginBlock.modelData,
                                                 modelData.kind, modelData.action)
                                Row {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.gap(8)
                                    SBtn {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: grantRow.confirming
                                        label: grantRow.modelData.kind === "ui"
                                               ? "Allow UI anyway" : "Allow anyway"
                                        danger: true
                                        onClicked: {
                                            grantRow.confirming = false
                                            win.applyPluginGrant(pluginBlock.modelData,
                                                                 grantRow.modelData.kind, true,
                                                                 grantRow.modelData.action)
                                        }
                                    }
                                    SToggle {
                                        anchors.right: undefined; anchors.verticalCenter: undefined
                                        checked: PG.checked(pluginBlock.modelData,
                                                            grantRow.modelData.kind,
                                                            grantRow.modelData.action)
                                        onToggled: (v) => {
                                            if (v && grantRow.needsConfirm && pluginBlock.warned
                                                && !PG.checked(pluginBlock.modelData,
                                                               grantRow.modelData.kind,
                                                               grantRow.modelData.action)) {
                                                grantRow.confirming = true
                                                return
                                            }
                                            grantRow.confirming = false
                                            win.applyPluginGrant(pluginBlock.modelData,
                                                                 grantRow.modelData.kind, v,
                                                                 grantRow.modelData.action)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- one plugin's own settings, rendered from its manifest schema.
            // The schema has no description field and none is invented here: a
            // row is its label, its value, and its options.
            Column {
                visible: win.tab === "plugins" && win.pluginSettingsFor.length > 0
                width: col.width

                SRow {
                    name: {
                        for (const p of win.pluginList)
                            if (p.id === win.pluginSettingsFor) return p.name
                        return win.pluginSettingsFor
                    }
                    SBtn { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                           label: "Back"; onClicked: win.pluginSettingsFor = "" }
                }
                // This plugin's commands, with the same key button and gesture
                // picker the Shortcuts tab uses.
                Repeater {
                    model: win.pluginShortcutRows
                    ShortcutRow { required property var modelData; row: modelData }
                }
                // This plugin's buttons, on this plugin's page.
                Repeater {
                    // the player bar's are placed in Appearance › Arrange like any
                    // button; only the title bar's are toggled here
                    model: win.barButtonRows.filter(
                        (b) => b.pluginId === win.pluginSettingsFor && b.bar === "title")
                    delegate: SRow {
                        required property var modelData
                        name: modelData.ownLabel
                        SToggle { checked: modelData.shown
                                  onToggled: (v) => win.showBarButton(modelData.pluginId,
                                                                      modelData.id, v) }
                    }
                }
                Repeater {
                    model: win.pluginSettingsSchema
                    SRow {
                        id: pluginField
                        required property var modelData
                        readonly property var val: win.pluginSettingsValues[modelData.key]
                        // a `file` row carries TWO controls (Open folder + the
                        // select), so the default reserve runs the label under them
                        reserve: modelData.type === "file" ? 270 : 176
                        name: modelData.label
                        // Shows the slider's working value, like the native sliders above; the
                        // persisted value would freeze until release while the handle moves.
                        desc: modelData.type === "slider" && pluginSlider.visible
                              ? String(Math.round(pluginSlider.shown * 100) / 100) : ""
                        // An action's button reaches entry.qml, which exists only while this plugin
                        // holds the ui grant and its QML is loaded; otherwise the row is hidden.
                        visible: modelData.type !== "action"
                                 || (PluginUi && PluginUi.has(win.pluginSettingsFor))
                        SToggle {
                            visible: pluginField.modelData.type === "toggle"
                            checked: pluginField.val === true
                            onToggled: (v) => win.setPluginSetting(pluginField.modelData.key, v)
                        }
                        SSelect {
                            visible: pluginField.modelData.type === "select"
                            options: pluginField.modelData.options || []
                            value: String(pluginField.val === undefined ? "" : pluginField.val)
                            onPicked: (v) => win.setPluginSetting(pluginField.modelData.key, v)
                        }
                        SSlider {
                            id: pluginSlider
                            visible: pluginField.modelData.type === "slider"
                            from: pluginField.modelData.from === undefined ? 0 : pluginField.modelData.from
                            to: pluginField.modelData.to === undefined ? 1 : pluginField.modelData.to
                            step: pluginField.modelData.step === undefined ? 0 : pluginField.modelData.step
                            value: Number(pluginField.val === undefined ? 0 : pluginField.val)
                            onCommitted: (v) => win.setPluginSetting(pluginField.modelData.key, v)
                        }
                        SInput {
                            visible: pluginField.modelData.type === "text"
                            text: String(pluginField.val === undefined ? "" : pluginField.val)
                            placeholder: pluginField.modelData.placeholder || ""
                            onCommitted: (v) => win.setPluginSetting(pluginField.modelData.key, v)
                        }
                        // `file` picks from what is actually in the plugin's data
                        // subdirectory, so the folder button is the other half of
                        // the control, not decoration.
                        Row {
                            visible: pluginField.modelData.type === "file"
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(8)
                            SBtn {
                                anchors.verticalCenter: parent.verticalCenter
                                label: "Open folder"
                                onClicked: {
                                    Qt.openUrlExternally("file://" + Settings.dataDir
                                        + "/plugin-data/" + win.pluginSettingsFor
                                        + "/" + (pluginField.modelData.dir || ""))
                                    win.fetchPluginSettingFiles(pluginField.modelData.key)
                                }
                            }
                            SSelect {
                                anchors.right: undefined; anchors.verticalCenter: undefined
                                options: win.pluginFileOptions(pluginField.modelData)
                                value: String(pluginField.val === undefined ? "" : pluginField.val)
                                onPicked: (v) => win.setPluginSetting(pluginField.modelData.key, v)
                            }
                        }
                        // An action emits a signal on the plugin's entry.qml root. Addressed by
                        // plugin id: several plugins can be loaded, and an unkeyed call would fire
                        // this key on whichever one melo built last.
                        SBtn {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: pluginField.modelData.type === "action"
                            label: "Run"
                            onClicked: {
                                PluginUi.invokeAction(win.pluginSettingsFor,
                                                      pluginField.modelData.key)
                                win.fetchPluginSettings()   // it may have written settings
                            }
                        }
                    }
                }
            }
        }
    }

    // window-local overlays (this is a separate window from Main's);
    // selects use a REAL popup window so they can cross the window edge
    DropMenu { id: winMenu }
    PromptDialog { id: winPrompt }
    ColorPicker { id: colorPicker; objectName: "colorPicker" }
    EffectPicker { id: effectPicker; objectName: "effectPicker" }
    // native portal file chooser (QtQuick.Dialogs dropped from the build)
    QtObject {
        id: bgFileDialog
        function open() {
            Portal.openFile("settings-bg", "Choose background image", "Images",
                            ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.gif"], false)
        }
    }

    // invisible key sink focused while recording a shortcut
    Item {
        id: keyCatcher
        focus: win.recordingAction.length > 0
        Keys.onPressed: (e) => {
            if (win.recordingAction.length === 0) return
            e.accepted = true
            if (e.key === Qt.Key_Escape) { win.recordingAction = ""; return }
            const seq = SC.fromKeyEvent(e)
            console.warn("[shortcut-rec] key=", e.key, "mods=", e.modifiers,
                         "text=", e.text, "->", seq)
            if (seq) win.setShortcut(win.recordingAction, seq)
        }
    }

    // The popup has no reliable input grab on Wayland, so this catcher eats the first
    // press anywhere in the settings window and closes it; the window deactivating (a
    // click on another window) also closes it.
    MouseArea {
        anchors.fill: parent
        z: 500
        visible: winMenu.visible
        onPressed: winMenu.close()
    }
    // grace period: opening the popup itself may shuffle activation
    onActiveChanged: if (!active && winMenu.visible
                         && Date.now() - winMenu.openedAt > 200) winMenu.close()

    // glass follows the theme (and its knobs) while the window is open
    Connections {
        target: ThemeBackend
        function onThemeChanged() { if (win.visible) win.applyGlass() }
    }

    QtObject {
        id: importDialog
        function open() {
            Portal.openFile("settings-import", "Import audio files", "Audio",
                            ["*.mp3", "*.opus", "*.ogg", "*.webm", "*.m4a", "*.flac", "*.wav"], true)
        }
    }
    Connections {
        target: Portal
        function onPicked(tag, paths) {
            if (tag === "shape-image" && paths.length) win.shapeWith("image", "file://" + paths[0])
            else if (tag === "settings-bg") win.setBg({ src: "file://" + paths[0] })
            else if (tag === "settings-import" && paths.length)
                win.importPaths(paths)
            else if (tag === "theme-export" && paths.length)
                ThemeBackend.exportTheme(ThemeBackend.activeId, paths[0])
            else if (tag === "theme-import" && paths.length) {
                ThemeBackend.importTheme(paths[0])   // on the list; picked like any other, or not
            }
            // "preset-export:style" — the kind cannot come from the file here,
            // because the file is what is being written
            else if (tag.indexOf("preset-export:") === 0 && paths.length) {
                const kind = tag.slice("preset-export:".length)
                ThemeBackend.exportCurrent(kind, kind, paths[0])
            }
            else if (tag === "preset-import" && paths.length)
                ThemeBackend.importPreset(paths[0])
            else if (tag === "glyph-import" && paths.length) {
                const r = ThemeBackend.importGlyph(paths[0])
                const e = {}
                for (const k in win.glyphError) e[k] = win.glyphError[k]
                if (r.ok) { delete e[win.glyphFor]; win.setGlyph(win.glyphFor, r.entry) }
                else e[win.glyphFor] = r.error
                win.glyphError = e
            }
        }
    }

    Shortcut { sequence: "Escape"; onActivated: win.visible = false }
}
