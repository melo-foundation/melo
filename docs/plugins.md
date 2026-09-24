# Writing melo plugins

A plugin adds an audio source (`source`), playback event hooks (`events`), or
QML that runs inside melo (`ui`). `source` and `events` code runs in its own
Node process, limited to its own folder and data dir. `ui` QML runs in melo's
process with melo's full authority: read
[What containment does not stop](#what-containment-does-not-stop) before you
ship one.

> API version **3**. Manifests with `apiVersion` 1, 2 or 3 load; `ui` requires
> `apiVersion: 3`.

## Quick start

A plugin is a folder in the user plugin directory:

- Linux: `~/.config/melo/plugins/<id>/`
- Windows: `%USERPROFILE%\.config\melo\plugins\<id>\`

Its data dir is `plugin-data/<id>/` beside `plugins/`.

```
my-plugin/
  manifest.json
  main.js          # ESM; default-exports activate(melo)   — source/events
  ui/              # QML                                   — ui
  assets/          # optional (e.g. a source icon)
```

Templates in the repo: `sidecar/test-fixtures/sample-source/` (a source),
`sidecar/test-fixtures/hello-ui/` (a `ui` plugin).

1. Copy the folder into the plugin directory (**Settings → Plugins → Open
   folder** opens it).
2. Open **Settings → Plugins**. The tab rescans the folder; no restart.
3. Turn the plugin on. A plugin with a ⚠ warning needs **Enable anyway**; every
   `ui` plugin has one. Enabling a `ui` plugin loads its QML.
4. Turn on any grant rows under it: `rawNetwork` (needs **Allow anyway**) and
   one row per `intercept` action.

## manifest.json

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "apiVersion": 1,
  "author": "you",
  "description": "what it does",
  "capabilities": ["source", "events"],
  "entry": { "sidecar": "main.js" },
  "permissions": {
    "network": ["api.example.com", "*.example.com"],
    "rawNetwork": false,
    "intercept": ["play"]
  }
}
```

Required: `id`, `name`, `version`, `apiVersion`, `entry`. A manifest error
disables the plugin and shows the message in the Plugins tab.

| field | meaning |
|-------|---------|
| `id` | path-safe slug: letters, digits, `_`, `-`, starting with a letter or digit. Namespaces the plugin's track ids and data dir |
| `apiVersion` | **1**, **2**, or **3**. `ui` needs 3 |
| `capabilities` | `"source"`, `"events"`, `"ui"`. `"dsp"` and `"vis"` are reserved; they and any other value are a manifest error |
| `entry.sidecar` | the ESM file to load, inside the plugin folder |
| `entry.qml` | the QML shared-state root for a `ui` plugin, inside the plugin folder. Requires a `ui` block |
| `ui` | windows, buttons, slots, fills; see [The `ui` capability](#the-ui-capability) |
| `settings` | rows on the plugin's settings page; see [Settings schema](#settings-schema) |
| `commands` | `{ id, label, default? }[]` for a `ui` plugin, invoked as `<pluginId>.<id>`; see [Commands](#commands) |
| `permissions.network` | hostnames `fetch` may reach. `*.x.com` matches `x.com` and any subdomain |
| `permissions.rawNetwork` | `true` to request `node:net`/`tls`/`dgram`/`http`/`https`/`http2` and `WebSocket`. Takes effect only when the user turns on the `rawNetwork` row; the `network` allowlist does not apply to those sockets |
| `permissions.intercept` | [catalog](#intercepts) actions to handle before melo does. Each becomes a grant row the user turns on |

`entry` needs `sidecar`, `qml`, or both. A permissions key other than these three
loads with the warning `manifest.json: unknown permission "<key>" — ignored, and
grants nothing`.

## The `melo` API

Default-export `activate(melo)` from `main.js`:

```js
export default function activate(melo) {
  // --- audio source ---
  melo.registerSource({
    id: "my-plugin",
    name: "My Plugin",
    // { tracks, continuation } — continuation is an opaque token or null
    search: async (query, { continuation }) => ({ tracks: [...], continuation }),
    // { url, duration?, title?, channel? }  (headers/mime are not read)
    resolveStream: async (trackId) => ({ url }),
  })

  // --- playback events ---
  melo.player.on("trackChanged", ({ track }) => {})   // { id,title,channel,duration,source }
  melo.player.on("stateChanged", ({ playing, position }) => {})
  melo.player.on("seeked",       ({ position }) => {})
  melo.player.on("stopped",      () => {})            // no track loaded

  // --- storage (JSON kv, persisted in the plugin's data dir) ---
  melo.storage.get(key)
  melo.storage.set(key, value)

  // --- logging (-> melo's stderr, prefixed [plugin:<id>]) ---
  melo.log("hello")
}
```

### Track shape

```js
{ id: "myp:123",         // namespace your ids
  source: "my-plugin",   // must equal your source id — routes stream resolve
  title, channel, duration /* seconds */, thumbnail /* url */ }
```

Do not use `youtube` as a source id; melo resolves those tracks itself.

`resolveStream` returns a directly playable `url`. Optional fields: `duration`
(seconds, used when above 0), `title` (used when the track has none), `channel`
(replaces the track's). `headers` and `mime` are not read: put any credentials
the CDN needs into the URL.

Library downloads fail for plugin tracks: melo hands the track `id` to yt-dlp as
a YouTube video id.

## The `ui` capability

QML loads while the plugin is enabled. Plugin windows show in both the full
window and the mini player. Show and hide them through
[commands](#commands); a hidden window keeps its QML loaded.

```json
{
  "id": "hello-ui", "name": "Hello UI", "version": "0.1.0",
  "apiVersion": 3,
  "capabilities": ["ui"],
  "entry": { "qml": "ui/Entry.qml" },
  "ui": {
    "snap": { "distance": 10 },
    "windows": [
      { "id": "main", "qml": "ui/Main.qml", "width": 320, "height": 80, "primary": true },
      { "id": "eq", "qml": "ui/Eq.qml", "width": 320, "height": 116,
        "snapTo": "main", "initial": "hidden", "shade": { "height": 14 } }
    ]
  }
}
```

A `ui` block declares at least one of `windows`, `slots`, `buttons`, `fills`.
Every number in it is a whole pixel count.

| `ui.windows[]` field | meaning |
|---|---|
| `id` | slug, unique within the plugin; the key in `MeloUi.window` |
| `qml` | the window's QML file, inside the plugin folder |
| `width`, `height` | initial size, positive |
| `primary` | exactly one window sets it |
| `snapTo` | the window id this one docks to. A cycle is a manifest error |
| `initial` | `"shown"` (default) or `"hidden"` |
| `shade` | `{ "height": n }`: collapsed height for `toggleShade()` |
| `resize` | `{ "axes": "v"\|"h"\|"vh", "stepH", "stepW", "minHeight", "minWidth" }`; see [Resizable windows](#resizable-windows) |

`ui.snap.distance`: how close, in pixels, two window edges must be to snap.
Default 10, 0 to turn snapping off, 200 at most.

### `ui.buttons` — a control beside melo's own

```json
"ui": {
  "windows": [ ... ],
  "buttons": [
    { "id": "group", "bar": "player", "command": "toggleGroup",
      "icon": "ui/group.png", "label": "My windows" }
  ]
}
```

| field | meaning |
|---|---|
| `id` | slug, unique within your plugin |
| `bar` | `"player"` or `"title"` |
| `command` | one of your own `commands`. Any other name is a manifest error |
| `icon` | an image inside your plugin folder |
| `label` | the tooltip, and the button's name in the settings that hide it |

No limit on count. A `title` button appears once the plugin is enabled; the user
hides it on your plugin's page. A `player` button appears where the user places
it in **Settings → Appearance → Player → Arrange**.

To take over one of melo's own buttons, declare the matching
[intercept](#intercepts) (`toggleEq`, `toggleQueue`, …).

### `ui.fills` — a text and surface fill of your own

```json
"ui": {
  "fills": [
    { "id": "wave", "name": "Wave", "shader": "fills/wave.frag.qsb",
      "colours": 1, "shaped": false }
  ]
}
```

| field | meaning |
|---|---|
| `id` | slug, unique within your plugin; the picker names the fill `<pluginId>.<id>` |
| `name` | what the picker shows |
| `shader` | a `.qsb` inside your plugin folder. Bake it: `qsb --glsl "300es,120,150" --hlsl 50 --msl 12 -o wave.frag.qsb wave.frag` |
| `colours` | 0, 1, 2 or 3. Default 1. Any other value is a manifest error |
| `base` | `true` when the shader paints the entry's own colour (`colourA`). Default: `colours` is 1 or more |
| `palette` | `true` when the shader takes a list of colours (`pal0`…`pal5`, `palN`). Default: `colours` is 2 or more |
| `shaped` | `true` when the shader reads the glyph coverage's shape (an edge, a level); the picker then previews it on letters |

The fill appears in the colour picker once the plugin is enabled, and applies
to any ink, any surface, and an ink's halo colour.

Write a Qt `ShaderEffect` fragment shader with exactly this block:

```glsl
#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(binding = 1) uniform sampler2D mask;   // glyph coverage; 1x1 blank on a surface
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  colourA;   // the entry's colour, straight rgb
    vec4  pal0, pal1, pal2, pal3, pal4, pal5;   // params.colours, up to six
    vec4  geo0;      // origin.xy, size.xy — this item in the window, px
    vec4  geo1;      // unit.xy (800 in the app, the item's own size in a preview), hasMask, 0
    vec4  par;       // line height in px on text (0 on a surface), scale, angle (degrees), speed
    float time;      // seconds, shared by every fill; your phase is time * par.w
    float palN;      // how many of pal0..pal5 are set; 0 means "your classic look"
};
void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p = (geo0.xy + uv * geo0.zw) / geo1.x * par.y;   // window space, one pattern per unit
    vec3 c = /* your colour at p */ colourA.rgb;
    float cover = geo1.z > 0.5 ? texture(mask, uv).a : 1.0;
    fragColor = vec4(c, 1.0) * cover * qt_Opacity;         // premultiplied
}
```

`time` pauses while the window is moved or resized. Multiply it by `par.w`
(speed, −1 … 1): speed 0 stands still, a negative speed runs backwards. One
pixel of `mask` is `1.0 / geo0.zw`.

### `ui.slots` — filling one of melo's places

```json
"ui": {
  "windows": [ ... ],
  "slots": { "eq": "ui/EqPanel.qml" }
}
```

Slot ids: `playerBar`, `titleBar`, `searchBar`, `tabBar`, `queuePanel`, `home`,
`library`, `search`, `visualizer`, `background`, `eq`. Any other id is a
manifest error naming it.

The user binds a slot to your plugin in **Settings → Appearance** (Mode:
**Full**). One occupant per slot. Only `visualizer` and `queuePanel` draw; the
others can be declared and picked, and show nothing.

melo sets your slot root's geometry. Lay out against your own `width`/`height`:

| slot | width | height |
| --- | --- | --- |
| `visualizer` | the view area | the view area |
| `queuePanel` | your `implicitWidth`, or 320 if it is 0 | melo's, top to bottom |

For `queuePanel`, set `implicitWidth` on your root. Binding it to your own
`width` is a binding loop.

A slot occupant can walk `parent` into melo's window and call melo's objects.
Do not.

Slot QML has no window of its own: no title bar, no drag, no shape.
`MeloUi.window.<id>` moves one of your windows, which may be closed. Give each
slot its own QML file.

Do not name any QML file `Plugin.qml` or `MeloUi.qml`: melo refuses to load
the plugin. Name the entry file `Entry.qml`.

Each window's QML gets two injected names:

- `MeloUi`: the bridge, below.
- `Plugin`: the root object of `entry.qml`, shared across your windows.

```qml
// ui/Main.qml
import QtQuick
Rectangle {
    color: "#202020"
    MouseArea { anchors.fill: parent; onPressed: MeloUi.window.main.startDrag() }
    Text {
        // .values.<key>, not .get() — a method call is not a reactive binding
        visible: MeloUi.settings.values.showTitle === true
        color: "white"
        text: MeloUi.player.hasTrack ? MeloUi.player.title : "nothing playing"
    }
}
```

`MeloUi` exposes:

| | |
|---|---|
| `player` | `playing loading position duration title channel hasTrack volume balance shuffle repeat`; `play() pause() stop() next() prev() seek(s) setVolume(v) setBalance(v) setShuffle(on) setRepeat(mode)`. `volume` 0..1, `balance` −1..1, `repeat` `0` off, `1` one, `2` all. `stop()` pauses and seeks to 0 |
| `queue` | `model currentIndex count`; `jumpTo(i) removeAt(i) move(from,to) clear()`. `model` is read-only |
| `suggestions` | `model count`; `play(i)`. melo's suggested tracks, separate from the queue. `model` is read-only, with the queue's roles plus `isAutoplay` |
| `settings` | `values` (bind to `values.<key>`); `get(key) set(key,value)` |
| `eq` | `bands` (10, dB, −24..+12), `preamp` (dB, −12..+12); `setBand(i, db) setPreamp(db)` |
| `spectrum` | `bins() wave() binCount() waveCount()`, signal `updated` |
| `archives` | `get(settingsKey)`: an archive facade, or `null`; see [Archives](#archives) |
| `window` | `{ <id>: { id x y width height visible shaded, show() hide() toggleShade() startDrag() startResize() setShape(polygons) } }`. Geometry is read-only |
| `app` | `openPluginSettings()`, `setScale(x)`, `exitMiniMode()`, `setShellHidden(on)`, `setWindowsAlwaysUp(on)`; see below |
| `pluginId`, `pluginDir` | |

`queue.model` roles: `trackId title channel duration thumbnail active played`.
Change the queue through `MeloUi.queue`; writes to the model are ignored.

`eq.bands` and `eq.preamp` read and write melo's live equaliser. A `setBand`
shows in melo's EQ window as **Custom** and does not overwrite the user's saved
preset. While the user has melo's EQ off, your writes still reach the audio,
melo's EQ window does not show them, and turning the EQ back on re-applies the
user's curve. melo's EQ switch does not reset `preamp`.

`MeloUi.app.openPluginSettings()` opens your plugin's page in **Settings →
Plugins**.

`MeloUi.app.setScale(x)` scales your whole window group: geometry, masks, resize
steps and snap distance. Range 0.5–4.0, clamped.

`MeloUi.app.exitMiniMode()` hides every window your plugin owns. Show them again
from a command. Wire it to your window's close button.

`MeloUi.app.setShellHidden(true)` hides melo's own window while your windows are
up; `false` shows it. Use it when your windows carry the transport controls.

`MeloUi.app.setWindowsAlwaysUp(true)` keeps your windows on screen, above other
apps, while melo is minimized. `false` minimizes them with melo.

When your windows go away (plugin disabled, a settings change that rebuilds it,
`exitMiniMode()`), melo shows its own window and resets both requests. Call them
again once your windows are back up.

### Commands

A `ui` plugin declares commands in its manifest:

```json
"commands": [
  { "id": "toggleGroup", "label": "Show / hide my windows", "default": "" }
]
```

Each entry needs `id` (a lowercase letter, then letters or digits) and
`label`. `default` is optional: a catalog gesture id (`playerBar.doubleClick`,
`compact.escape`, `titleBar.doubleClick`) or a `KeyboardEvent.code` key string
(`Space`, `ctrl+KeyL`). A default containing `.` that is not a catalog gesture
is a manifest error. A key default that another command already holds loads
with the warning `<pluginId>.<id>: default key already taken` and is cleared.
melo binds no default: the user binds every plugin command.

The user binds your commands on your plugin's page, **Settings → Plugins → ⚙**,
one row per command. **Settings → Shortcuts** lists melo's commands only. Do not
ship a settings row that binds a key or gesture.

Handle commands in entry QML:

```qml
function command(id) { /* ... */ }
```

`id` is your command id without the `<pluginId>.` prefix. Do not dispatch
commands through `action` settings rows.

A gesture has one occupant across melo and every plugin: binding
`playerBar.doubleClick` to `my-plugin.toggleGroup` takes it from whatever held
it. Defaults: `playerBar.doubleClick` and `compact.escape` run
`toggleCompact`; `titleBar.doubleClick` runs `toggleMaximize`.
`compact.escape` fires only in compact mode, so Escape still leaves compact
after you take `playerBar.doubleClick`.

Keys fire while any melo window, yours included, has focus. A key with no
modifier does not fire while a text field has focus.

### Intercepts

Declare catalog actions in `permissions.intercept`. For each action the user
turns on in the Plugins tab, melo calls `function intercept(id)` on your entry
QML root instead of acting.

Catalog: `play`, `pause`, `stop`, `next`, `prev`, `toggleCompact`, and melo's
chrome buttons `toggleQueue`, `toggleEq`, `toggleVisualizer`, `toggleSearch`,
`openSettings`, `togglePin`. Any other id (`queue.add`) is a manifest error.

The return value of `intercept(id)` is ignored: once it runs, melo does nothing
for that action. Granting `toggleEq` means melo's equaliser button runs your
handler and never opens melo's equaliser.

For `play`, `pause`, `stop`, `next` and `prev`, return without calling through
to swallow the action, or call `MeloUi.player.play()`, `MeloUi.player.pause()`,
`MeloUi.player.stop()`, `MeloUi.player.next()` or `MeloUi.player.prev()` to
run melo's own. These calls skip intercepts and cannot loop. The other seven
actions have no call-through.

Swallowing `toggleCompact` with no other way to expand leaves the user in
compact mode until they turn off the grant.

The end-of-track advance is not offered as `next`. MPRIS Stop is offered as
`stop`.

If two plugins hold the same action, the one listed last in **Settings →
Plugins** receives it.

Fixture: `sidecar/test-fixtures/hello-intercept/` intercepts `play`, with a
**Swallow play** toggle (`swallowPlay`).

```qml
// ui/Entry.qml
QtObject {
    function intercept(id) {
        if (id !== "play")
            return
        if (MeloUi.settings.values.swallowPlay)
            return
        MeloUi.player.play()
    }
}
```

### Non-rectangular windows

`setShape(polygons)` unions a list of polygons into the window's mask;
`setShape([])` makes the window rectangular again. A polygon is a list of
points (`{x,y}` objects or `[x,y]` pairs) or a flat list `[x,y,x,y,…]`:

```qml
MeloUi.window.main.setShape([[5,0, 270,0, 270,115, 5,115],
                             [3,1, 272,1, 272,114, 3,114]])
```

Limits: 512 polygons, 8192 points per polygon, coordinates within ±32767.
melo drops a polygon with an odd coordinate count, a non-numeric or infinite
corner, fewer than three corners, or a cost past the budget, applies the rest,
and prints on stderr:

```
[melo] plugin <id>: window <id>: <n> of <m> shape polygons ignored (the rest still apply)
```

If nothing survives, the window stays rectangular.

The budget is **32768 units** per call. An axis-aligned rectangle costs 1. Any
other polygon costs ceil(points / 2) × its height in pixels, so a traced outline
of several hundred points can be dropped. Build shapes from rectangles.

| | `setShape` changes | it does not change |
|---|---|---|
| Wayland | where clicks land (the input region) | what is drawn — nothing is clipped |
| X11 | what is drawn (the bounding shape) | where clicks land |

Do both: draw the transparency into your sprite alpha, and call `setShape`.

After `toggleShade()` or a user resize, call `setShape` again for the new size.

### Resizable windows

A window with a `resize` block can be resized by the user dragging, and no other
way. Put a grip in the window and call `startResize()`:

```qml
MouseArea {
    x: root.width - 16; y: root.height - 16
    width: 16; height: 16
    cursorShape: Qt.SizeVerCursor
    onPressed: MeloUi.window.playlist.startResize()
}
```

`startResize()` takes no arguments. `axes` sets the edge: `"v"` the bottom,
`"h"` the right, `"vh"` the bottom-right corner. It does nothing on a window
with no `resize` block or on a shaded window.

melo puts every size on the manifest's grid before your QML sees it:

- Permitted heights are `minHeight + k*stepH` (widths likewise). With no
  minimum, the declared `height`/`width` is the anchor.
- An axis not in `axes` stays at its declared value.
- A window with no `resize` block is fixed size.
- Declare a `width`/`height` your own `resize` block permits. Otherwise melo
  opens the window at the nearest permitted size and prints
  `[melo] plugin <id>: window <id> declares WxH, which its own resize block does not permit — opening at WxH`.

Windows docked below a resized window move to its new edge.

melo sets `width` and `height` on your root item after every size change. Lay
out content against `height` (or `width`), not a constant.

### Archives

A `file` settings row lets the user pick a file from a folder in your plugin's
data dir. `MeloUi.archives` opens that file as a zip and serves its entries.

```qml
// ui/Entry.qml — one facade per key, shared by all your windows
QtObject {
    readonly property var skin: MeloUi.archives.get("skin")   // the settings key
    readonly property bool ready: skin !== null && skin.ready
    // Read `generation` in any binding that calls text(); without it, swapping
    // one valid archive for another keeps the previous archive's text.
    readonly property var palette:
        ready && skin.generation >= 0 ? parse(skin.text("viscolor.txt")) : []
}
```

| | |
|---|---|
| `get(settingsKey)` | the facade for that key, or `null` if your manifest declares no `file` row with that key. Returns the same object every time |
| `ready` | an archive is open. `error` says why not |
| `names` | every entry, as stored |
| `image(name)` | an `image://` url for `Image.source`, or `""` if the archive has no such entry |
| `text(name)` | the entry's text, or `""` |
| `generation` | how many archives this facade has opened. Read it in any binding that calls `text()` |
| `pixel(name, x, y)` | one pixel of an image entry as `#rrggbb`, or `""` for a missing entry or out-of-range coordinate |

Every call takes a settings key or an entry name, never a path.

An entry that is corrupt, uses an unsupported compression method, or would take
the archive past 64 MB decoded is missing; the rest load.

Read `ready` in the same binding that calls `image()`, or the source stays empty
when the archive loads late:

```qml
Image { source: (a && a.ready) ? a.image("main.bmp") : "" }
```

Read `ready` in the binding itself, not through a bool of your own. `ready` stays
`true` when the user picks a new file, so a bool of your own does not change and
bindings on it keep the previous file's content, with no error:

```qml
readonly property bool ready: a !== null && a.ready
readonly property var palette: ready ? parse(a.text("colors.txt")) : []   // WRONG
readonly property var palette:
    (a !== null && a.ready) ? parse(a.text("colors.txt")) : []            // right
```

`Image.sourceClipRect` does nothing on these urls. To draw one rectangle of a
sprite sheet, clip an offset child:

```qml
Item {
    width: r.width; height: r.height; clip: true
    Image { x: -r.x; y: -r.y; source: a.image(sheet); smooth: false }
}
```

#### Entry names

- Names match case-insensitively: `text.bmp` finds `TEXT.bmp`.
- When every entry shares a leading folder (`1/main.bmp`, `1/pledit.txt`, …),
  melo strips it, so `image("main.bmp")` finds `1/main.bmp`. When entries share
  no folder, melo strips the folder holding `main.bmp`, unless that makes two
  entries collide.
- A name is tried as written first, then stripped.

Ask for the plain name (`main.bmp`).

### Settings schema

`settings` is an array of rows on your plugin's page, **Settings → Plugins → ⚙**.
Read the values as `MeloUi.settings.values`.

| `type` | extra fields | control |
|---|---|---|
| `toggle` | `default` | switch |
| `select` | `options: [{label, value}]` (non-empty, strings), `default` | dropdown |
| `slider` | `from`, `to`, `step`, `default` | slider |
| `text` | `placeholder`, `default` | text field |
| `file` | `dir` (relative to your plugin data dir, no `..`; melo does not create it), `extensions` | dropdown of the files in that folder, plus **Open folder** |
| `action` | — | button; emits a same-named signal on your `entry.qml` root |

Every row needs `key` (slug) and `label`. There is no description field; unknown
fields are dropped.

```json
{ "key": "resetAccent", "type": "action", "label": "Reset accent" }
```
```qml
// ui/Entry.qml
QtObject {
    signal resetAccent()
    onResetAccent: MeloUi.settings.set("accent", "green")
}
```

- A key with no stored value reads as its `default`.
- `set()` on a key the schema does not declare, or on an `action` key, is
  ignored. A stored key the schema no longer declares is dropped.
- Values reach you as soon as they are written.
- An `action` row shows only while your QML is loaded.

Your plugin's page holds these rows, a binding row per command, and a toggle
per title-bar button. The ⚙ shows while the plugin is enabled and declares at
least one `settings` row; otherwise open the page with
`MeloUi.app.openPluginSettings()`. The page closes when the plugin is turned
off.

### What containment does not stop

A `ui` plugin's QML runs in its own engine with a curated import path
(`Qt.labs.*`, `QtQuick.LocalStorage` and `QtQuick.Dialogs` do not resolve) and
only `MeloUi` and `Plugin` as context properties. It is not sandboxed:

- **Network:** any host. The manifest `network` allowlist applies to the Node
  process only.
- **Files:** `Image` and `Qt.createComponent("file:///…")` read any path.
- **Native code:** a directory import loads the shared object its `qmldir`
  names.
- **melo's QML types:** `import Melo 1.0` resolves. melo's five registered types
  (`Visualizer`, `BackgroundItem`, `ParticlesItem`, `BlendRect`, `WindowShape`)
  refuse to run in a plugin's engine.
- **melo's window:** the shell's item tree is reachable through `parent` and
  `Window.window.transientParent`.
- **Freezing melo:** a `while(1)` in plugin QML hangs the app.
- **Spoofing:** a plugin can draw a convincing melo-branded prompt.
- **Window captions:** a plugin can rename its own windows, and melo's KWin
  scripts match windows by caption.

In AppImage builds the importable modules are the ones melo's own QML imports.
See also `SECURITY.md`.

### Known limitations

- **Drag-snapping on Wayland needs KWin.** Under another Wayland compositor,
  `snapTo` applies only when melo moves the window. X11 and Windows work.

  Docking is one-way: dragging a window carries the windows docked to it, and
  dragging a docked window detaches it (its own docked windows follow it).

  melo re-docks a group on initial placement, a shade toggle, `show()` /
  `hide()` on any window in the chain, and while it follows a dragged window.

  A hidden window takes no space: hiding one closes the gap, showing it pushes
  the rest back out.
- **Initial placement needs a compositor geometry report.** Without one, windows
  keep the compositor's placement, undocked, and melo prints
  `[melo] plugin <id>: no KWin geometry report — plugin windows keep the compositor's placement (not docked)`.
  On KWin/Wayland the placement can also fail to stick; the group then stays at
  the compositor's placement and still drags as a unit.
- **No programmatic resize.** `MeloUi.window.<id>` has no `resize(w, h)`; offer a
  grip, not a button. See [Resizable windows](#resizable-windows).
- **`MeloUi.queue` cannot add tracks.** It jumps, removes, moves and clears.

Working example: `sidecar/test-fixtures/hello-ui/`.

## Sandbox — what is and isn't enforced

This section covers `entry.sidecar` only. For `ui` QML see
[What containment does not stop](#what-containment-does-not-stop).

Each plugin runs as a separate Node process launched with `--permission`:

- **Enforced by Node:** read access to the plugin folder, its data dir and
  melo's plugin host folder; write access to the data dir only; no child
  processes, worker threads or native addons.
- **Network:** `fetch` only, to the manifest's `network` hostnames. Any other
  host rejects with `melo: <host> is not in this plugin's manifest network allowlist`.
  Low-level socket modules and `globalThis.WebSocket` throw
  `melo: <module> is not available to this plugin (rawNetwork is not granted)`
  until the user turns on `rawNetwork`. The socket-module block needs Node ≥ 22.15.
- **Limit:** the network restriction is JavaScript-level. A plugin granted
  `rawNetwork`, or one exploiting a Node escape, is not contained. Review a
  plugin before you install it.

melo scans the plugin's `.js`/`.mjs`/`.cjs`/`.qml` files on load. Raw-socket
imports, `eval`/`new Function`/`process.binding`/`process.getBuiltinModule`,
`Qt.createQmlObject`, `Qt.createComponent("file:…")`, and `rawNetwork` show as
⚠ warnings in the Plugins tab and require **Enable anyway**.

## Lifecycle

- Enabled plugins start with melo and when switched on in Settings. A
  `rawNetwork` grant change takes effect when the plugin is turned off and on,
  or on restart.
- A plugin that exits is restarted up to 3 times in 60 s, then marked
  **crashed** until the user turns it on again.
- A plugin that throws during load, or has no default-exported `activate`, is
  marked **error** with the message and is not restarted.
- Timeouts: `search` 10 s, `resolveStream` 30 s.
- **One directory per plugin id.** When two directories declare the same `id`,
  the first by name loads and the other shows *duplicate plugin id "x": already
  loaded from another directory*. A copy such as `my-plugin.bak` counts.

## Checking plugin QML

```bash
./scripts/qmllint-plugins.sh ~/.config/melo
```

Runs `qmllint` (needs `qmllint-qt6` or `qmllint`) on the `.qml` files one or two
folders deep inside each plugin under `<dir>/plugins/` (`Entry.qml`,
`ui/Main.qml`). It fails on any diagnostic except `Unqualified access` on
`Plugin` and `MeloUi`.

A passing run parses and resolves types; it does not run your QML. These all
pass:

- a binding loop,
- a `TypeError` inside any signal handler or function body,
- a misspelled member of `MeloUi` or `Plugin`,
- anything drawn in the wrong place, or not drawn at all.

Test your QML by running it.

## Debugging

**Plugin process** (`activate(melo)`): `melo.log`, `console.log` and stderr go
to melo's stderr prefixed `[plugin:<id>]`. A load failure's message shows in the
Plugins tab.

**`ui` plugin QML:** `console.log` needs both variables:

```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_RULES="qml.debug=true" melo
```

- `QT_FORCE_STDERR_LOGGING=1` sends Qt's messages to stderr.
- `QT_LOGGING_RULES="qml.debug=true"` shows debug-level messages. `*.debug`
  also enables `qt.qpa.*`.

`console.log`, `console.warn` and `console.error` print unprefixed as
`qml: <message>`; `console.warn` and `console.error` need only the first
variable. Lines prefixed `[plugin:<id>]` are engine diagnostics: parse errors,
binding errors, `ReferenceError`.
