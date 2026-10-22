.pragma library

// The art URLs Now Playing tries, largest first: it shows the art full width,
// so it asks for more than the card's thumbnail. YouTube's video thumbnails:
// 1280, then 720, then the thumbnail. YouTube Music's (googleusercontent and
// ggpht) carry their size after "=": 1200 square, as YouTube Music's player asks.
// A download's own thumbnail (melo/thumbs/<video id>.*) is the card's 360 one:
// the large picture kept beside it first (library.ts cacheLargeArt), then the
// video's online ones, the card's last.
function sizes(thumb) {
    const t = String(thumb || "")
    const dl = /^(file:\/\/.*\/thumbs\/)([A-Za-z0-9_-]{11})\.[a-z]+$/.exec(t)
    if (dl)
        return [dl[1] + dl[2] + "-large.jpg",
                "https://i.ytimg.com/vi/" + dl[2] + "/maxresdefault.jpg",
                "https://i.ytimg.com/vi/" + dl[2] + "/hq720.jpg", t]
    const vi = /ytimg\.com\/vi(?:_webp)?\/([^\/]+)\//.exec(t)
    if (vi)
        return ["https://i.ytimg.com/vi/" + vi[1] + "/maxresdefault.jpg",
                "https://i.ytimg.com/vi/" + vi[1] + "/hq720.jpg", t]
    const gu = /^(https:\/\/[a-z0-9-]+\.(?:googleusercontent|ggpht)\.com\/[^=]+)=([^?#]*)$/.exec(t)
    if (gu) {
        // keep the flags after the size (-l90-rj and the like), drop the size itself
        const flags = gu[2].split("-").filter(p => !/^[whs]\d+$/.test(p))
        return [gu[1] + "=" + ["w1200", "h1200"].concat(flags).join("-"), t]
    }
    return [t]
}
