import QtQuick
import QtTest
import "../../src/qml/components/skeletonmodel.js" as Flow

// Search rows: a YouTube Music album says its kind and year and no count; a
// count shows only when the source gives one.
Item {
    ListModel { id: m }

    TestCase {
        name: "SearchRows"

        function test_album_label_has_kind_and_year_and_no_count() {
            const row = Flow.toRow({ id: "OLAK5uy_x", title: "Random Access Memories", channel: "Daft Punk",
                                     isPlaylist: true, videoCount: 0, kind: "Album", year: 2013 })
            compare(Flow.playlistLabel(row, true), "Album · 2013")
            compare(Flow.playlistLabel(row, false), "Album · 2013")
        }

        function test_youtube_playlist_with_a_count_is_unchanged() {
            const row = Flow.toRow({ id: "PLx", title: "Mix", channel: "Someone", isPlaylist: true, videoCount: 12 })
            compare(Flow.playlistLabel(row, true), "Playlist · 12 videos")
        }

        function test_no_count_shows_no_count() {
            const row = Flow.toRow({ id: "PLy", title: "Mix", channel: "Someone", isPlaylist: true, videoCount: 0, kind: "Playlist" })
            compare(Flow.playlistLabel(row, true), "Playlist")
        }

        function test_song_keeps_its_album_through_the_model() {
            m.clear()
            m.append(Flow.blank())
            Flow.apply(m, [{ id: "uSFXOBaqiR8", title: "Veridis Quo (Edit)", channel: "Daft Punk", duration: 165,
                             thumbnail: "", album: "Veridis Quo", albumId: "MPREb_ACdoDdB5hLk", year: 2001,
                             artists: ["Daft Punk", "Someone Else"] }])
            const r = m.get(0)
            compare(r.album, "Veridis Quo")
            compare(r.albumId, "MPREb_ACdoDdB5hLk")
            compare(r.year, 2001)
            compare(r.artists.split("\n"), ["Daft Punk", "Someone Else"])
        }
    }
}
