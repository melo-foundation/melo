import QtQuick
import QtTest
import "../../src/qml/components/nowplaying/artsizes.js" as ArtSizes

// Now Playing's art, largest first, for both of YouTube's picture hosts
TestCase {
    name: "ArtSizes"

    function test_youtube_thumbnails_try_1280_then_720() {
        const t = "https://i.ytimg.com/vi/abcDEF12345/hqdefault.jpg?sqp=x&rs=y"
        compare(ArtSizes.sizes(t), ["https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg",
                                     "https://i.ytimg.com/vi/abcDEF12345/hq720.jpg", t])
    }
    function test_youtube_music_art_asks_for_1200_and_keeps_its_flags() {
        const t = "https://lh3.googleusercontent.com/AbC_d-Ef=w120-h120-l90-rj"
        compare(ArtSizes.sizes(t), ["https://lh3.googleusercontent.com/AbC_d-Ef=w1200-h1200-l90-rj", t])
        const s = "https://yt3.ggpht.com/xyz=s88-c-k-c0x00ffffff-no-rj"
        compare(ArtSizes.sizes(s)[0], "https://yt3.ggpht.com/xyz=w1200-h1200-c-k-c0x00ffffff-no-rj")
    }
    function test_a_downloads_thumbnail_tries_the_videos_large_ones_first() {
        const t = "file:///home/x/Music/melo/thumbs/F5V5fxKVLXo.webp"
        compare(ArtSizes.sizes(t), ["file:///home/x/Music/melo/thumbs/F5V5fxKVLXo-large.jpg",
                                     "https://i.ytimg.com/vi/F5V5fxKVLXo/maxresdefault.jpg",
                                     "https://i.ytimg.com/vi/F5V5fxKVLXo/hq720.jpg", t])
    }
    function test_anything_else_is_left_alone() {
        compare(ArtSizes.sizes("file:///home/x/Music/melo/thumbs/a.jpg"), ["file:///home/x/Music/melo/thumbs/a.jpg"])
        compare(ArtSizes.sizes("file:///home/x/Music/melo/albumart/F5V5fxKVLXo.jpg"),
                ["file:///home/x/Music/melo/albumart/F5V5fxKVLXo.jpg"])
        compare(ArtSizes.sizes("https://lh3.googleusercontent.com/AbC"), ["https://lh3.googleusercontent.com/AbC"])
        compare(ArtSizes.sizes(""), [""])
    }
}
