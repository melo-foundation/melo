import QtQuick
import QtQuick.Window
import ".."
import "accounts.js" as Accounts
import "onboarding.js" as Onboarding
import "locales.js" as Locales

// First run, in its own window: the look, the account, playback. Shown until
// Settings.ui.onboardingDone, which Skip and Done both set. Every pick applies as
// it is made, so the look previews on the real window and Skip keeps it.
// The look rows are the settings window's built-in presets; the account list is
// accounts.js, shared with the title bar and settings.
MeloWindow {
    id: obw
    heading: "Set up melo"
    // As tall as the tallest page, and no page changes height: accounts are a
    // dropdown, and a row that depends on another setting is disabled in
    // place rather than hidden. So the window never resizes and no page
    // scrolls. The cap to most of the screen is for very small screens only.
    width: 420
    readonly property real fitH: Math.min(Screen.desktopAvailableHeight * 0.85,
                     obw.body.y + Theme.inset("dialog", "top") + stepCol.height
                     + Theme.gap(14) + Theme.ctl(26) + Theme.inset("dialog", "bottom") + obw.frB)
    height: fitH
    minimumWidth: 380
    minimumHeight: 160
    // first run holds the app: the look step previews on the main window
    // behind it, but nothing there is for pressing until this is done
    modality: Qt.ApplicationModal
    // the title bar's close and Escape end first run as Skip does
    onCloseRequested: obw.finish()

    readonly property real labelW: Theme.ctl(96)
    readonly property real rowH: Theme.ctl(30)
    property int step: 0
    readonly property int steps: 3

    property var localeList: []
    property var regionList: []
    property int themeGen: 0   // bumped when a look pick lands, so the rows re-read what is on
    property bool cfOnSkip: false
    // the services are auto-tag's; with it off they are disabled, not rewritten
    readonly property bool autoTagOn: Settings.metadataAutoEnrich === "new"

    // the accounts come from AccountStore, shared with the title bar and the
    // settings window, so a sign-in shows in all three at once
    readonly property var entries: AccountStore.entries
    readonly property var moods: Onboarding.moodSuggestions(AccountStore.profiles)

    function open() {
        cfOnSkip = Settings.uiGet("crossfadeOnSkip", false) === true
        step = 0
        refresh()
        openWindow()
    }
    // Last.fm is asked only with a key. Done with it on and none entered asks:
    // turning it off is the explicit button, and dismissing the question takes
    // you to the key — Escape must not switch a service off.
    function tryFinish() {
        if (autoTagOn && Settings.tagLastfm && !Settings.lastfmApiKey.trim().length) {
            obPrompt.askDialog("Last.fm needs an API key", "Turn Last.fm off", "Add key", "", (off) => {
                if (off) { Settings.tagLastfm = false; obw.finish() }
                else { obw.step = 2; keyInput.forceActiveFocus() }
            })
            return
        }
        finish()
    }
    function finish() {
        Settings.uiSet("onboardingDone", true)
        visible = false
    }

    function rpcReady() { return typeof sidecar !== "undefined" && sidecar && sidecar.ready }
    function refresh() {
        if (!rpcReady()) return
        AccountStore.refresh(true)
        sidecar.rpc("settings/locales", {}, (r) => {
            if (!r.ok || !r.result) return
            obw.localeList = r.result.locales || []
            obw.regionList = r.result.regions || []
        })
    }
    Connections {
        target: typeof sidecar !== "undefined" ? sidecar : null
        function onReadyChanged() { if (obw.visible && sidecar.ready) obw.refresh() }
    }

    // a new profile is one to use: made, then switched to — and the switch is
    // what brings it into AccountStore's lists
    function createProfile(name) {
        const n = (name || "").trim()
        if (!n.length || !rpcReady()) return
        sidecar.rpc("cookies/create", { name: n }, () => Accounts.applyChoice({ kind: "guest", id: n }, Settings))
    }

    function presetName(kind) {
        const dep = obw.themeGen
        const id = ThemeBackend.matchingPreset(kind)
        const hit = ThemeBackend.presets(kind).find((p) => p.id === id)
        return hit ? hit.name : "Custom"
    }
    function presetMenu(head, kind) {
        const p = head.mapToItem(null, 0, head.height + 2)
        obMenu.openAt(head.Window.window, p.x, p.y, ThemeBackend.presets(kind).map((x) => ({
            label: x.name, check: x.id === ThemeBackend.matchingPreset(kind),
            act: () => { ThemeBackend.applyPreset(kind, x.id); obw.themeGen++ },
        })), head)
    }
    function choiceMenu(head, options, current, pick) {
        const p = head.mapToItem(null, 0, head.height + 2)
        obMenu.openAt(head.Window.window, p.x, p.y, options.map((o) => ({
            label: o.label, check: o.value === current, act: () => pick(o.value),
        })), head)
    }

    function accountRows() {
        return obw.entries.map((e) => ({ label: e.label, check: e.active,
                                         act: () => Accounts.applyChoice(e, Settings) }))
    }
    function accountMenu() {
        AccountStore.refresh(true)   // re-read every browser: a login changes outside melo
        const p = accountHead.mapToItem(null, 0, accountHead.height + 2)
        obMenu.openAt(accountHead.Window.window, p.x, p.y, accountRows(), accountHead)
    }
    onEntriesChanged: if (obMenu.visible && obMenu.owner === accountHead) obMenu.actions = accountRows()

    DropMenu { id: obMenu }
    // its own prompt: Main's would open behind this window
    PromptDialog { id: obPrompt }

    Item {
        parent: obw.body
        anchors.fill: parent

        Flickable {
            id: stepFlick
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footerBar.top
            anchors.bottomMargin: Theme.gap(14)
            anchors.topMargin: Theme.inset("dialog", "top")
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.rightMargin: Theme.inset("dialog", "right")
            contentHeight: stepCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // The stack is as tall as its tallest page, so Next and Back never resize the
            // window. Hidden pages use opacity, not visible (which zeroes their height), and
            // take no input.
            Item {
                id: stepCol
                width: stepFlick.width
                height: Math.max(page0.implicitHeight, page1.implicitHeight, page2.implicitHeight)

                // ---------- 1 · look ----------
                Column {
                    id: page0
                    anchors.top: parent.top
                    opacity: obw.step === 0 ? 1 : 0
                    enabled: obw.step === 0
                    width: parent.width
                    spacing: Theme.gap(6)
                    Repeater {
                        model: [ { label: "Colour", kind: "palette" },
                                 { label: "Transparency", kind: "transparency" },
                                 { label: "Player", kind: "player" } ]
                        delegate: Item {
                            required property var modelData
                            width: stepCol.width
                            height: obw.rowH
                            InkText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                ink: "text"
                                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                            }
                            SelectHead {
                                id: lookHead
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - obw.labelW
                                label: obw.presetName(modelData.kind)
                                menu: obMenu
                                onClicked: obw.presetMenu(lookHead, modelData.kind)
                            }
                        }
                    }

                    // Window fade and pin: how the window sits on the desktop, read and
                    // written exactly as the settings window and the title bar do
                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Window fade"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        SelectHead {
                            id: fadeHead
                            readonly property var options: [ { value: "off", label: "Off" },
                                                             { value: "hover", label: "When the mouse leaves melo" },
                                                             { value: "focus", label: "When you switch to another window" } ]
                            readonly property string current: String(ThemeBackend.settings["fadeMode"] || "off")
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - obw.labelW
                            label: (options.find((o) => o.value === current) || options[0]).label
                            menu: obMenu
                            onClicked: obw.choiceMenu(fadeHead, options, current,
                                                      (v) => ThemeBackend.setThemeSetting("fadeMode", v))
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Always on top"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            readonly property bool pinned: !!(obw.transientParent && obw.transientParent.alwaysOnTop)
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: pinned
                            // the title bar's own command, so a plugin that intercepts
                            // togglePin sees this one too
                            onToggled: (v) => { if (v !== pinned) CommandMap.invoke("togglePin") }
                        }
                    }
                }

                // ---------- 2 · account ----------
                Column {
                    id: page1
                    anchors.top: parent.top
                    opacity: obw.step === 1 ? 1 : 0
                    enabled: obw.step === 1
                    width: parent.width
                    spacing: Theme.gap(6)

                    // A dropdown: a list would grow with every profile made here, and
                    // the pages share one height, so every page would scroll
                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Account/Profile"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        SelectHead {
                            id: accountHead
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - obw.labelW
                            label: { const a = Accounts.activeOf(obw.entries); return a ? a.label : "No account" }
                            menu: obMenu
                            onClicked: obw.accountMenu()
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "New profile"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.gap(6)
                            Repeater {
                                model: obw.moods
                                delegate: PushButton {
                                    required property string modelData
                                    label: modelData
                                    onClicked: obw.createProfile(modelData)
                                }
                            }
                            PushButton {
                                label: "+"
                                onClicked: obPrompt.promptDialog("New profile name", "",
                                                                                 (n) => obw.createProfile(n))
                            }
                        }
                    }

                    Item {
                        enabled: Settings.cookieSource !== "none"
                        opacity: enabled ? 1 : 0.4
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Improve recommendations"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Settings.sendPlayback
                            onToggled: (v) => Settings.sendPlayback = v
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Home"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        SelectHead {
                            id: homeHead
                            readonly property var options: [ { value: "youtube", label: "YouTube" },
                                                             { value: "ytmusic", label: "YouTube Music" } ]
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - obw.labelW
                            label: Settings.homeSource === "ytmusic" ? "YouTube Music" : "YouTube"
                            menu: obMenu
                            onClicked: obw.choiceMenu(homeHead, options, Settings.homeSource,
                                                     (v) => Settings.homeSource = v)
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Language"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        SearchSelect {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - obw.labelW
                            options: Locales.options(obw.localeList)
                            value: Settings.language
                            placeholder: "System"
                            onPicked: (v) => Settings.language = v
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Region"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        SearchSelect {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - obw.labelW
                            options: Locales.regionOptions(obw.regionList)
                            value: Settings.region
                            placeholder: "System"
                            onPicked: (v) => Settings.region = v
                        }
                    }
                }

                // ---------- 3 · playback ----------
                Column {
                    id: page2
                    anchors.top: parent.top
                    opacity: obw.step === 2 ? 1 : 0
                    enabled: obw.step === 2
                    width: parent.width
                    spacing: Theme.gap(6)

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            id: cfName
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Crossfade"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        InkText {
                            anchors.left: cfName.right
                            anchors.leftMargin: Theme.gap(8)
                            anchors.baseline: cfName.baseline
                            text: Onboarding.crossfadeLabel(cfSlider.shown)
                            ink: "textDim"
                            font { pixelSize: Theme.fs(11); family: Theme.fontFamily }
                        }
                        MSlider {
                            id: cfSlider
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            from: 0; to: 12; step: 0.5
                            value: Settings.crossfadeSeconds
                            holdFlick: stepFlick
                            onCommitted: (v) => Settings.crossfadeSeconds = v
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Crossfade on skip"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: obw.cfOnSkip
                            // stored as the settings window stores it
                            onToggled: (v) => { obw.cfOnSkip = v; Settings.uiSet("crossfadeOnSkip", v) }
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Skip silence"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Settings.silenceSkip
                            onToggled: (v) => Settings.silenceSkip = v
                        }
                    }

                    Item {
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Auto-tag new tracks"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Settings.metadataAutoEnrich === "new"
                            onToggled: (v) => Settings.metadataAutoEnrich = v ? "new" : "off"
                        }
                    }

                    Item {
                        enabled: obw.autoTagOn
                        opacity: enabled ? 1 : 0.4
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Tag with MusicBrainz"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Settings.tagMusicBrainz
                            onToggled: (v) => Settings.tagMusicBrainz = v
                        }
                    }

                    Item {
                        enabled: obw.autoTagOn
                        opacity: enabled ? 1 : 0.4
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Tag with Deezer"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Settings.tagDeezer
                            onToggled: (v) => Settings.tagDeezer = v
                        }
                    }

                    Item {
                        enabled: obw.autoTagOn
                        opacity: enabled ? 1 : 0.4
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Tag with Last.fm"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        MToggle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: Settings.tagLastfm
                            onToggled: (v) => Settings.tagLastfm = v
                        }
                    }

                    // Last.fm is asked only with a key, so the key sits under its switch
                    Item {
                        enabled: obw.autoTagOn && Settings.tagLastfm
                        opacity: enabled ? 1 : 0.4
                        width: parent.width
                        height: obw.rowH
                        InkText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Last.fm API key"
                            ink: "text"
                            font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                        }
                        Surface {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - obw.labelW - Theme.ctl(40)
                            height: Theme.ctl(24)
                            radius: Theme.radiusMd
                            role: "input"
                            borderWidth: 1
                            borderRole: keyInput.activeFocus ? "borderStrong" : "border"
                            TextInput {
                                id: keyInput
                                anchors.fill: parent
                                anchors.leftMargin: Theme.gap(8); anchors.rightMargin: Theme.gap(8)
                                verticalAlignment: TextInput.AlignVCenter
                                color: Theme.text
                                clip: true
                                text: Settings.lastfmApiKey
                                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                                onEditingFinished: if (text.trim() !== Settings.lastfmApiKey) Settings.lastfmApiKey = text.trim()
                            }
                            InkText {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.gap(8)
                                visible: keyInput.text.length === 0 && !keyInput.activeFocus
                                text: "Required"
                                ink: "danger"
                                font { pixelSize: Theme.fs(12); family: Theme.fontFamily }
                            }
                        }
                    }

                }
            }
        }

        Item {
            id: footerBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.inset("dialog", "left")
            anchors.rightMargin: Theme.inset("dialog", "right")
            anchors.bottomMargin: Theme.inset("dialog", "bottom")
            height: Theme.ctl(26)

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap(5)
                Repeater {
                    model: obw.steps
                    delegate: Rectangle {
                        required property int index
                        width: 6; height: 6; radius: 3
                        color: index === obw.step ? Theme.accent : Theme.border
                    }
                }
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap(8)
                component StepBtn: PushButton { pad: 24; fontSize: 12 }
                StepBtn {
                    label: obw.step === 0 ? "Skip" : "Back"
                    onClicked: obw.step === 0 ? obw.finish() : obw.step--
                }
                StepBtn {
                    label: obw.step === obw.steps - 1 ? "Done" : "Next"
                    accent: true
                    onClicked: obw.step === obw.steps - 1 ? obw.tryFinish() : obw.step++
                }
            }
        }
    }
}
