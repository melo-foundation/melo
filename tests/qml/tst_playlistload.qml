import QtQuick
import QtTest
import "../../src/qml/views"

// The playlist view's loading ends: an album loads whole from its page, an
// empty or failed page ends paging, and trimmed placeholders leave the screen.
Item {
    id: rootItem
    width: 500; height: 700

    property var calls: []
    // set: the next page is answered with it 30 ms after it is asked for, as fast as a cached page
    property var morePage: null
    function rpc(method, params, cb) {
        calls.push({ method: method, params: params, cb: cb })
        if (method === "yt/getPlaylistMore" && morePage) moreTimer.start()
    }
    function answer(i, result) { calls[i].cb({ ok: true, result: result }) }
    Timer { id: moreTimer; interval: 30; onTriggered: rootItem.answer(rootItem.calls.length - 1, rootItem.morePage) }

    PlaylistView { id: pv; anchors.fill: parent; layout: "grid"; rpc: rootItem.rpc }

    function track(id) { return { id: id, title: "T " + id, channel: "C", duration: 60, thumbnail: "" } }

    Timer { interval: 50; running: true; repeat: true; onTriggered: tc.shownTilesNow = tc.shownTiles() }

    TestCase {
        id: tc
        name: "PlaylistLoad"
        when: windowShown

        function init() { rootItem.calls = []; rootItem.morePage = null }

        function gridView() {
            for (let i = 0; i < pv.children.length; i++)
                if (pv.children[i].cellWidth !== undefined) return pv.children[i]
            return null
        }
        // delegates a person can see: in the viewport and not faded out
        function shownTiles() {
            const g = gridView()
            if (!g) return 0
            const kids = g.contentItem.children
            let n = 0
            for (let i = 0; i < kids.length; i++) {
                const k = kids[i]
                // a pooled delegate (index -1) still drawn is the bug this guards
                if (k.index === undefined || !k.visible || k.opacity < 0.01) continue
                if (k.y + k.height > g.contentY && k.y < g.contentY + g.height) n++
            }
            return n
        }

        function test_album_loads_whole_from_its_page() {
            pv.open("OLAK5uy_a", "Blah Blah Blah", null,
                    { browseId: "MPREb_a", artist: "Bilal Saeed", kind: "Single", year: 2016 })
            compare(rootItem.calls.length, 1)
            compare(rootItem.calls[0].method, "yt/getAlbum")
            compare(rootItem.calls[0].params.browseId, "MPREb_a")
            compare(rootItem.calls[0].params.playlistId, "OLAK5uy_a")
            compare(pv.playlistSubtitle, "Bilal Saeed · Single · 2016")
            verify(pv.loading)
            rootItem.answer(0, { ok: true, title: "Blah Blah Blah", artist: "Bilal Saeed", kind: "Single", year: 2016,
                                 tracks: [track("aaaaaaaaaaa")], cursor: "" })
            compare(pv.loading, false)
            compare(pv.listCursor, "")
            wait(500)
            compare(rootItem.calls.length, 1, "no page asked for after the album")
            compare(pv.fetchingMore, false)
            compare(pv.allTracks().length, 1)
            tryCompare(this, "shownTilesNow", 1, 2000)
        }
        property int shownTilesNow: 0

        function test_a_playlist_still_loads_as_a_playlist() {
            pv.open("PLplain", "Mine", null, null)
            compare(rootItem.calls[0].method, "yt/getPlaylistTracks")
            compare(pv.playlistSubtitle, "")
        }

        function test_an_empty_page_ends_paging() {
            pv.open("PLshort", "Short", null, null)
            rootItem.answer(0, { ok: true, title: "Short", tracks: [track("bbbbbbbbbbb")], cursor: "c1" })
            // the viewport is not full: the view asks for the next page itself
            tryVerify(() => rootItem.calls.length === 2, 2000)
            compare(rootItem.calls[1].method, "yt/getPlaylistMore")
            verify(pv.fetchingMore)
            // an empty page with a cursor still ends it
            rootItem.answer(1, { ok: true, tracks: [], cursor: "c1" })
            compare(pv.fetchingMore, false)
            compare(pv.listCursor, "")
            wait(500)
            compare(rootItem.calls.length, 2, "no third request")
            compare(pv.allTracks().length, 1)
            tryCompare(this, "shownTilesNow", 1, 2000)
        }

        function test_a_failed_page_ends_paging() {
            pv.open("PLfail", "Fail", null, null)
            rootItem.answer(0, { ok: true, title: "Fail", tracks: [track("ccccccccccc")], cursor: "c2" })
            tryVerify(() => rootItem.calls.length === 2, 2000)
            rootItem.calls[1].cb({ ok: false, error: "expired" })
            compare(pv.fetchingMore, false)
            compare(pv.listCursor, "")
            wait(500)
            compare(rootItem.calls.length, 2)
            tryCompare(this, "shownTilesNow", 1, 2000)
        }

        // a model change during the trim's fade must not hold the trimmed placeholders on screen
        function test_trimmed_placeholders_leave_after_a_fast_last_page() {
            rootItem.morePage = { ok: true, tracks: [], cursor: "" }
            pv.open("PLfast", "Fast", null, null)
            rootItem.answer(0, { ok: true, title: "Fast", tracks: [track("ddddddddddd")], cursor: "c3" })
            wait(1500)
            compare(rootItem.calls.length, 2)
            compare(pv.fetchingMore, false)
            compare(shownTilesNow, 1)
        }

        function test_a_failed_album_shows_the_error_and_stops() {
            pv.open("OLAK5uy_b", "Gone", null, { browseId: "MPREb_b", artist: "X", kind: "Album", year: 0 })
            rootItem.calls[0].cb({ ok: true, result: { ok: false, error: "Album unavailable" } })
            compare(pv.loading, false)
            compare(pv.plError, "Album unavailable")
            compare(pv.allTracks().length, 0)
        }
    }
}
