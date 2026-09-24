import QtQuick
import QtTest
import "../../src/qml/views"

// Navigating to a different playlist must not leave the previous one's rows
// mounted: apply() fills in place (so skeletons morph), which across a
// navigation would keep old rows, and their decoded thumbnails, on screen.
Item {
    id: rootItem
    width: 500; height: 300

    PlaylistView { id: pv; anchors.fill: parent; layout: "list" }

    TestCase {
        name: "PlaylistNav"
        when: windowShown

        function titlesNow() { return pv.allTracks().map(t => t.title) }
        function thumbsNow() { return pv.allTracks().map(t => t.thumbnail) }

        function test_a_no_stale_rows_across_navigation() {
            pv.open("PL_A", "A", [
                { id: "aaaaaaaaaaa", title: "ALPHA ONE", channel: "ca", duration: 10, thumbnail: "" },
                { id: "bbbbbbbbbbb", title: "ALPHA TWO", channel: "ca", duration: 20, thumbnail: "" }
            ])
            compare(titlesNow().length, 2, "playlist A loaded")

            // navigate to a different playlist, also with known tracks
            pv.open("PL_B", "B", [
                { id: "ccccccccccc", title: "BETA ONE", channel: "cb", duration: 30, thumbnail: "" }
            ])
            const t = titlesNow()
            verify(t.indexOf("ALPHA ONE") === -1, "no stale A row: " + JSON.stringify(t))
            verify(t.indexOf("ALPHA TWO") === -1, "no stale A row: " + JSON.stringify(t))
            compare(t.length, 1, "only B remains")
        }

        function test_c_seeded_mix_skeleton_is_capped() {
            // seeded mixes return ~20 from one watch-next page
            compare(pv.expectedMax("RDAMVM9bQmwjT-1mw"), 20, "RDAMVM seeded")
            compare(pv.expectedMax("RD6ObvFPLk8eI"), 20, "RD<videoId> seeded")
            // curated mixes and playlists are real playlist objects
            compare(pv.expectedMax("RDMMYCoauaN_CMI"), 20, "RDMM seeded")
            compare(pv.expectedMax("RDCLAK5uy_nDL8KeBrUagwyISwNmyEiSfYgz1gVCesg"), 0, "RDCLAK curated")
            compare(pv.expectedMax("RDGMEMYH9CUrFO7CfLJpaD7UR85wVMBgPBgTEvi08"), 0, "RDGM seedless")
            compare(pv.expectedMax("RDAMPLPLabc"), 0, "RDAMPL curated")
            compare(pv.expectedMax("PLFgquLnL59alCl"), 0, "plain playlist")
            compare(pv.expectedMax(""), 0, "empty id")
        }

        function test_d_pagination_state_resets_on_navigation() {
            pv.open("PL_X", "X", [{ id: "fffffffffff", title: "X1", channel: "c", duration: 5, thumbnail: "" }])
            pv.listCursor = "stale-cursor"
            pv.fetchingMore = true
            pv.open("PL_Y", "Y", [{ id: "ggggggggggg", title: "Y1", channel: "c", duration: 5, thumbnail: "" }])
            compare(pv.listCursor, "", "cursor cleared on navigation")
            compare(pv.fetchingMore, false, "in-flight flag cleared")
        }

        function test_e_loadMore_is_a_noop_without_cursor() {
            pv.open("PL_Z", "Z", [{ id: "hhhhhhhhhhh", title: "Z1", channel: "c", duration: 5, thumbnail: "" }])
            const before = pv.allTracks().length
            pv.loadMore()   // no cursor -> must not append placeholders
            compare(pv.allTracks().length, before, "no rows added")
            compare(pv.fetchingMore, false, "did not mark in-flight")
        }

        function test_b_thumbnails_do_not_survive() {
            pv.open("PL_C", "C", [
                { id: "ddddddddddd", title: "GAMMA", channel: "cc", duration: 10,
                  thumbnail: "https://example.invalid/old.jpg" }
            ])
            compare(thumbsNow()[0], "https://example.invalid/old.jpg")
            pv.open("PL_D", "D", [
                { id: "eeeeeeeeeee", title: "DELTA", channel: "cd", duration: 10,
                  thumbnail: "https://example.invalid/new.jpg" }
            ])
            compare(thumbsNow().length, 1, "one row")
            compare(thumbsNow()[0], "https://example.invalid/new.jpg",
                    "thumbnail replaced, not carried over")
        }
    }
}
