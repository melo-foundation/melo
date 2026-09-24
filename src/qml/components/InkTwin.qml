import QtQuick
import QtQuick.Window
import Melo 1.0

// The texture twin of a ScrollText whose ink blends or adapts, loaded by source
// so ScrollText (in every list row) pays for HueLumText, BlendText and the Melo
// module only when a theme asks. `host` is the ScrollText.
//   adaptive with a backdrop            -> the shader, drawn plainly
//   adaptive with a backdrop and a mode -> the shader to a texture, drawn
//                                          through BlendRect with the mode
//   anything else                       -> BlendText: the mode, or invert
//                                          when adaptive has nothing to read
Item {
    id: tw
    property Item host: null
    readonly property var r: host ? host.inkRole : null
    readonly property bool adaptive: host ? host.adaptive : false
    readonly property bool useShader: adaptive && host && host.backdrop !== null
                                      && host.backdrop.Window.window === host.Window.window
    readonly property bool styled: host ? host.styled : false
    readonly property string mode: r ? r.blend : ""
    readonly property bool combo: (useShader || styled) && mode.length > 0
    Component.onCompleted: if (typeof MELO_INK_DEBUG !== "undefined" && MELO_INK_DEBUG)
        console.warn("[ink-twin]", host ? host.ink : "-", "useShader=" + useShader, "combo=" + combo,
                     "adaptive=" + adaptive, "hostWindow=" + (host ? host.Window.window : "-"),
                     "backdropWindow=" + (host && host.backdrop ? host.backdrop.Window.window : "-"))

    component Adapted: HueLumText {
        backdrop: tw.host.backdrop
        text: tw.host.text
        font: tw.host.font
        horizontalAlignment: tw.host.horizontalAlignment
        // ScrollText has none; a Text host centres its one line in its box
        verticalAlignment: tw.host.verticalAlignment === undefined ? Text.AlignTop : tw.host.verticalAlignment
        wrapMode: tw.host.labelWrap
        lineHeight: tw.host.lineHeight
        maximumLineCount: tw.host.maxLines
        elide: tw.host.labelElide
        hue: tw.r.amounts.x
        lum: tw.r.amounts.y
        sat: tw.r.amounts.z
    }

    component Styled: StyledText {
        text: tw.host.text
        font: tw.host.font
        horizontalAlignment: tw.host.horizontalAlignment
        verticalAlignment: tw.host.verticalAlignment === undefined ? Text.AlignTop : tw.host.verticalAlignment
        lineHeight: tw.host.lineHeight
        wrapMode: tw.host.labelWrap
        maximumLineCount: tw.host.maxLines
        elide: tw.host.labelElide
        kind: tw.r.source
        params: tw.r.params
        colourA: tw.r.colour
        layers: tw.r.layers
    }

    Loader {
        anchors.fill: parent
        active: tw.useShader && !tw.combo
        sourceComponent: Adapted { opacity: tw.r.amounts.w * tw.r.opacity }
    }
    Loader {
        anchors.fill: parent
        active: tw.styled && !tw.combo
        sourceComponent: Styled { opacity: tw.r.opacity }
    }
    Loader {
        anchors.fill: parent
        active: tw.combo
        sourceComponent: Item {
            // the shader to a texture (zero-sized clip: rendered, never drawn
            // — see BlendText for why) and BlendRect draws it with the mode
            Item {
                width: 0; height: 0; clip: true
                Loader {
                    id: comboSrc
                    width: tw.width; height: tw.height
                    layer.enabled: true
                    sourceComponent: tw.styled ? styledComp : adaptedComp
                    Component { id: adaptedComp; Adapted { opacity: tw.r.amounts.w } }
                    Component { id: styledComp; Styled {} }
                }
            }
            BlendRect {
                anchors.fill: parent
                source: comboSrc
                mode: tw.mode
                color: "#ffffff"
                opacity: tw.r.opacity
            }
        }
    }
    Loader {
        anchors.fill: parent
        active: !tw.useShader && !tw.styled && tw.r !== null
        sourceComponent: BlendText {
            text: tw.host.text
            font: tw.host.font
            horizontalAlignment: tw.host.horizontalAlignment
            wrapMode: tw.host.labelWrap
            maximumLineCount: tw.host.maxLines
            elide: tw.host.labelElide
            color: tw.r.colour
            blend: tw.adaptive ? "invert" : tw.mode
            opacity: tw.r.opacity
        }
    }
}
