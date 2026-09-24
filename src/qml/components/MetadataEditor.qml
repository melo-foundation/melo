import QtQuick
import QtQuick.Window
import ".."

// Edit Metadata window: artist/title/album/year/
// genre fields, heuristic suggestion, API lookup chain, art source picker
// with custom art file, Save / Clear / Cancel.
Window {
    // NOT "layer" — Item has a built-in layer property that shadows the id
    // inside any Repeater delegate, silently. See tst_themekeys.
    id: editor
    width: 400
    height: Math.min(col.implicitHeight + Theme.inset("dialog", "top")
                     + Theme.inset("dialog", "bottom") + titleBar.height, 700)
    minimumWidth: 340
    minimumHeight: 260
    visible: false
    color: "transparent"
    title: "melo metadata"
    flags: Qt.Window | Qt.FramelessWindowHint

    // its own surface, so it takes the same glass the other windows do
    // instead of riding on whatever the main window happened to be doing
    function applyGlass() {
        const on = Theme.glassBlur !== "off" && Theme.translucent("window")
        WindowCtl.setBlurRadius(Theme.windowRadius)
        WindowCtl.setBlurBehind(editor, on)
        WindowCtl.setBackgroundContrast(editor, on, Theme.glassContrast, Theme.glassSaturation)
    }
    onVisibleChanged: if (visible) { applyGlass(); requestActivate() }
    Connections {
        target: ThemeBackend
        function onThemeChanged() { if (editor.visible) editor.applyGlass() }
    }

    property string trackId
    property var track: null
    property var suggestion: null
    property bool lookupLoading: false
    property string lookupError

    property string fArtist
    property string fTitle
    property string fAlbum
    property string fYear
    property string fGenre
    property string artSource: "default"
    property string customArtFile
    property string albumArt
    property string albumArtFile
    // an imported file may name the video its plays count as; a YouTube
    // track's link is its own id and is shown, not edited
    readonly property bool isLocal: trackId.startsWith("local-")
    property string fLink
    property string linkWas
    property string linkError
    property string fileName
    property string fileError
    function watchUrl(id) { return id ? "https://www.youtube.com/watch?v=" + id : "" }

    function openFor(id) {
        trackId = id
        lookupError = ""; lookupLoading = false
        track = null; suggestion = null
        sidecar.rpc("metadata/get", { videoId: id }, (r) => {
            if (!r.ok || !r.result) return
            const t = r.result
            editor.track = t
            const m = t.metadata || {}
            fArtist = m.artist || ""
            fTitle = m.cleanTitle || ""
            fAlbum = m.album || ""
            fYear = m.year ? String(m.year) : ""
            fGenre = m.genre || ""
            artSource = m.artSource || "default"
            customArtFile = m.customArtFile || ""
            albumArt = m.albumArt || ""
            albumArtFile = m.albumArtFile || ""
            fLink = watchUrl(editor.isLocal ? (t.youtubeId || "") : t.id)
            linkWas = fLink; linkError = ""
            fileName = t.downloaded && t.fileName ? t.fileName : ""; fileError = ""
            editor.visible = true
            sidecar.rpc("metadata/suggest", { title: t.title, channel: t.channel }, (r2) => {
                if (r2.ok && r2.result) editor.suggestion = r2.result
            })
        })
    }

    function localArt(sub, f) {
        return "file://" + Settings.downloadPath + "/" + sub + "/" + f
    }
    function artUrl() {
        if (!track) return ""
        if (artSource === "custom" && customArtFile) return localArt("albumart", customArtFile)
        if (artSource === "album") {
            if (albumArtFile) return localArt("albumart", albumArtFile)
            if (albumArt) return albumArt
        }
        if (artSource === "thumbnail")
            return track.thumbnailFile ? localArt("thumbs", track.thumbnailFile) : (track.thumbnail || "")
        if (customArtFile) return localArt("albumart", customArtFile)
        if (albumArtFile) return localArt("albumart", albumArtFile)
        if (albumArt) return albumArt
        return track.thumbnailFile ? localArt("thumbs", track.thumbnailFile) : (track.thumbnail || "")
    }

    function applySuggestion(m) {
        if (!m) return
        if (m.artist) fArtist = m.artist
        if (m.cleanTitle) fTitle = m.cleanTitle
        if (m.album) fAlbum = m.album
        if (m.year) fYear = String(m.year)
        if (m.genre) fGenre = m.genre
    }

    function doLookup() {
        const a = fArtist || (suggestion && suggestion.artist) || (track && track.channel) || ""
        const t = fTitle || (suggestion && suggestion.cleanTitle) || (track && track.title) || ""
        if (!a && !t) return
        lookupLoading = true
        lookupError = ""
        const cleanChannel = track && track.channel
            ? track.channel.replace(/\s*-\s*Topic$/, "") : ""
        const params = { artist: a, title: t }
        if (cleanChannel && a !== cleanChannel) params.rawArtist = cleanChannel
        sidecar.rpc("metadata/lookup", params, (r) => {
            lookupLoading = false
            if (r.ok && r.result && r.result.ok) {
                const res = r.result.result
                applySuggestion(res)
                if (res.albumArt) {
                    editor.albumArt = res.albumArt
                    sidecar.rpc("metadata/cacheAlbumArt",
                        { videoId: editor.trackId, artUrl: res.albumArt }, (c) => {
                        if (c.ok && c.result && c.result.path) editor.albumArtFile = c.result.path
                    })
                }
            } else {
                lookupError = (r.result && r.result.error) || r.error || "No results found"
            }
        })
    }

    function save() {
        const md = { source: "manual" }
        if (fArtist.trim()) md.artist = fArtist.trim()
        if (fTitle.trim()) md.cleanTitle = fTitle.trim()
        if (fAlbum.trim()) md.album = fAlbum.trim()
        const y = parseInt(fYear)
        if (!isNaN(y)) md.year = y
        if (fGenre.trim()) md.genre = fGenre.trim()
        if (artSource !== "default") md.artSource = artSource
        if (customArtFile) md.customArtFile = customArtFile
        if (albumArt) md.albumArt = albumArt
        if (albumArtFile) md.albumArtFile = albumArtFile
        const finish = () => {
            sidecar.rpc("metadata/save", { videoId: trackId, metadata: md }, () => {})
            visible = false
        }
        if (!isLocal || fLink.trim() === linkWas.trim()) { finish(); return }
        // the link first: a bad one keeps the editor open to say so
        sidecar.rpc("library/setYoutubeLink", { videoId: trackId, link: fLink }, (r) => {
            const res = r.ok ? r.result : null
            if (!res || !res.ok) { linkError = (res && res.error) || r.error || "could not link"; return }
            finish()
        })
    }
    function clearMeta() {
        sidecar.rpc("metadata/save", { videoId: trackId, metadata: null }, () => {})
        visible = false
    }

    // native portal file chooser (QtQuick.Dialogs dropped from the build)
    QtObject {
        id: audioDialog
        function open() {
            Portal.openFile("metadata-audio", "Choose the audio file", "Audio",
                            ["*.mp3", "*.opus", "*.ogg", "*.webm", "*.m4a", "*.flac", "*.wav"], false)
        }
    }
    QtObject {
        id: artDialog
        function open() {
            Portal.openFile("metadata-art", "Choose cover art", "Images",
                            ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.avif"], false)
        }
    }
    Connections {
        target: Portal
        function onPicked(tag, paths) {
            if (tag === "metadata-audio" && paths.length) {
                editor.fileError = ""
                sidecar.rpc("library/replaceFile", { videoId: editor.trackId, path: paths[0] }, (r) => {
                    const res = r.ok ? r.result : null
                    if (!res || !res.ok) { editor.fileError = (res && res.error) || r.error || "could not use that file"; return }
                    sidecar.rpc("metadata/get", { videoId: editor.trackId }, (g) => {
                        if (g.ok && g.result) editor.fileName = g.result.fileName || ""
                    })
                })
                return
            }
            if (tag !== "metadata-art") return
            sidecar.rpc("metadata/importArtFile", { videoId: editor.trackId, path: paths[0] }, (r) => {
                if (r.ok && r.result && r.result.ok) {
                    editor.customArtFile = r.result.artFile
                    editor.artSource = "custom"
                }
            })
        }
    }

    Surface {
        anchors.fill: parent
        role: "window"
        radius: Theme.windowRadius
    }
    Surface {   // the page below the title bar, as the main window's below its header
        anchors.fill: parent
        anchors.topMargin: titleBar.height
        role: "page"
        topLeftRadius: 0; topRightRadius: 0
        bottomLeftRadius: Theme.windowRadius; bottomRightRadius: Theme.windowRadius
        visible: Theme.hasPage
    }
    Surface {   // the window border, above the title bar, as in the other windows
        anchors.fill: parent
        role: ""
        radius: Theme.windowRadius
        borderRole: "windowBorder"
        borderWidth: Theme.windowBorderWidth
        visible: Theme.windowBorder
        z: 1000
    }

    Surface {   // title bar
        id: titleBar
        width: parent.width
        height: Theme.titleBarH
        role: "title"
        topLeftRadius: Theme.windowRadius
        topRightRadius: Theme.windowRadius
        MouseArea { anchors.fill: parent; onPressed: editor.startSystemMove() }
        InkText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            anchors.left: parent.left; anchors.leftMargin: Theme.inset("title", "left")
            text: "Edit metadata"
            ink: "textOnTitle"
            font { pixelSize: Theme.fs(12); family: Theme.fontFamily; weight: Theme.weightMedium }
        }
        Item {
            anchors.right: parent.right; anchors.rightMargin: Theme.inset("title", "right")
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: (Theme.inset("title", "top") - Theme.inset("title", "bottom")) / 2
            width: Theme.ctl(26); height: Theme.ctl(20)
            IconButton {   // the same close as the main window's: its inks, its frame, its press
                anchors.centerIn: parent; name: "close"; size: Theme.glyph(12)
                ink: mdCloseMa.containsMouse ? "closeHover" : "close"
                face: "close"; framed: Theme.titleButtons === "button"
                hovered: mdCloseMa.containsMouse; pressed: mdCloseMa.pressed
                frameWidth: Theme.iconBtn; frameHeight: Math.min(Theme.iconBtn, Theme.ctl(20) + Theme.inset("title", "top") + Theme.inset("title", "bottom")) }
            MouseArea { id: mdCloseMa; anchors.fill: parent; hoverEnabled: true
                        onClicked: editor.visible = false }
        }
    }

    Item {
        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        Column {
            id: col
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.topMargin: Theme.inset("dialog", "top")
            anchors.rightMargin: Theme.inset("dialog", "right")
            spacing: Theme.gap(10)

            // original info + art
            Row {
                width: parent.width
                spacing: Theme.gap(10)
                Surface {
                    width: Theme.ctl(56); height: Theme.ctl(56); radius: Theme.radiusMd
                    role: "button"
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: editor.artUrl()
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(0, 0, 0, 0.5)
                        visible: artMa.containsMouse
                        InkText { anchors.centerIn: parent; text: "Edit"; ink: "textOnAccent"
                               font { pixelSize: Theme.fs(10); family: Theme.fontFamily } }
                    }
                    MouseArea { id: artMa; anchors.fill: parent; hoverEnabled: true
                                onClicked: artDialog.open() }
                }
                Column {
                    width: parent.width - 66
                    spacing: Theme.gap(2)
                    anchors.verticalCenter: parent.verticalCenter
                    InkText { width: parent.width; elide: Text.ElideRight
                           text: "Channel: " + (editor.track ? editor.track.channel : "")
                           ink: "textFaint"
                           font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                    InkText { width: parent.width; elide: Text.ElideRight
                           text: "Title: " + (editor.track ? editor.track.title : "")
                           ink: "textFaint"
                           font { pixelSize: Theme.fs(11); family: Theme.fontFamily } }
                }
            }

            // heuristic suggestion
            Surface {
                visible: editor.suggestion !== null
                width: parent.width
                height: sugRow.implicitHeight + 12
                radius: Theme.radiusMd
                role: "panel"
                Row {
                    id: sugRow
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.margins: Theme.gap(8)
                    spacing: Theme.gap(8)
                    InkText {
                        width: parent.width - 50
                        text: "Suggested: "
                              + (editor.suggestion ? (editor.suggestion.artist || "?") : "")
                              + " — "
                              + (editor.suggestion ? (editor.suggestion.cleanTitle || "?") : "")
                        ink: "textDim"
                        elide: Text.ElideRight
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                    }
                    InkText {
                        text: "Apply"
                        ink: sugMa.containsMouse ? "highlight" : "text"
                        font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        MouseArea { id: sugMa; anchors.fill: parent; hoverEnabled: true
                                    onClicked: editor.applySuggestion(editor.suggestion) }
                    }
                }
            }

            // fields
            component MField: Item {
                property alias label: lbl.text
                property alias value: input.text
                property alias readOnly: input.readOnly
                signal edited(string v)
                width: col.width
                height: 26
                InkText {
                    id: lbl
                    width: Math.max(Theme.sp(50), implicitWidth)
                    anchors.verticalCenter: parent.verticalCenter
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                Surface {
                    anchors.left: lbl.right; anchors.leftMargin: Theme.gap(6)
                    anchors.right: parent.right
                    height: 24
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Theme.radiusMd
                    role: "input"
                    borderWidth: 1
                    borderRole: input.activeFocus ? "borderStrong" : "border"
                    TextInput {
                        id: input
                        anchors.fill: parent
                        anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.text
                        clip: true
                        activeFocusOnTab: true   // Tab walks the fields in order
                        selectByMouse: true
                        font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        onTextEdited: parent.parent.edited(text)
                    }
                    // the text cursor over the whole box, padding included
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        cursorShape: Qt.IBeamCursor
                    }
                }
            }
            MField { label: "Artist"; value: editor.fArtist; onEdited: (v) => editor.fArtist = v }
            MField { label: "Title";  value: editor.fTitle;  onEdited: (v) => editor.fTitle = v }
            MField { label: "Album";  value: editor.fAlbum;  onEdited: (v) => editor.fAlbum = v }
            MField { label: "Year";   value: editor.fYear;   onEdited: (v) => editor.fYear = v }
            MField { label: "Genre";  value: editor.fGenre;  onEdited: (v) => editor.fGenre = v }
            MField { label: "YouTube"; value: editor.fLink; readOnly: !editor.isLocal
                     onEdited: (v) => { editor.fLink = v; editor.linkError = "" } }
            InkText {
                visible: editor.linkError.length > 0
                text: editor.linkError
                ink: "highlight"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }
            // the audio this entry plays; replacing it keeps the entry, so a
            // YouTube track still counts as its video
            Item {
                width: col.width
                height: 26
                InkText {
                    id: fileLbl
                    width: Math.max(Theme.sp(50), implicitWidth)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "File"
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                InkText {
                    anchors.left: fileLbl.right; anchors.leftMargin: Theme.gap(6)
                    anchors.right: replaceBtn.left; anchors.rightMargin: Theme.gap(8)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideMiddle
                    text: editor.fileName.length ? editor.fileName : "Not downloaded"
                    ink: editor.fileName.length ? "text" : "textDim"
                    font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                }
                EBtn { id: replaceBtn; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                       label: "Replace…"; onClicked: audioDialog.open() }
            }
            InkText {
                visible: editor.fileError.length > 0
                text: editor.fileError
                ink: "highlight"
                font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
            }

            // art source
            Item {
                width: parent.width
                height: 26
                InkText {
                    width: Math.max(Theme.sp(50), implicitWidth)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Art"
                    ink: "textDim"
                    font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                }
                SelectHead {
                    id: artSel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property var opts: [
                        { value: "default", label: "Auto" },
                        { value: "thumbnail", label: "Thumbnail" },
                        { value: "album", label: "Album art" },
                        { value: "custom", label: "Custom file" },
                    ]
                    function labelFor(v) {
                        for (const o of opts) if (o.value === v) return o.label
                        return v
                    }
                    label: labelFor(editor.artSource)
                    menu: mdMenu
                    onClicked: {
                        const p = artSel.mapToItem(null, 0, artSel.height)
                        mdMenu.openAt(editor, p.x, p.y, artSel.opts.map(o =>
                            ({ label: o.label, act: () => editor.artSource = o.value })), artSel)
                    }
                }
            }

            // footer: lookup + actions
            Item {
                width: parent.width
                height: Theme.btnH
                component EBtn: PushButton { pad: 20 }
                Row {
                    spacing: Theme.gap(8)
                    anchors.verticalCenter: parent.verticalCenter
                    EBtn { label: editor.lookupLoading ? "Looking up…" : "Lookup"
                           // a lookup already out: nothing to press until it lands
                           enabled: !editor.lookupLoading
                           onClicked: editor.doLookup() }
                    InkText {
                        visible: editor.lookupError.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: editor.lookupError
                        ink: "highlight"
                        font { pixelSize: Theme.fs(10); family: Theme.fontFamily }
                    }
                }
                Row {
                    spacing: Theme.gap(8)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    EBtn { label: "Clear"; onClicked: editor.clearMeta() }
                    EBtn { label: "Cancel"; onClicked: editor.visible = false }
                    EBtn { label: "Save"; accent: true; onClicked: editor.save() }
                }
            }
        }
    }

    DropMenu { id: mdMenu }

    Shortcut { sequence: "Escape"; enabled: editor.visible; onActivated: editor.visible = false }
}
