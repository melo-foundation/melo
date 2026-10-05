.pragma library

// The words, pills and cursor over the video on the poster face clear on idle
// or on a forced hide, and only while that video shows.
function clear(videoShown, onPoster, idle, forced) {
    return videoShown && onPoster && (forced || idle)
}

// The forced hide after a click on neutral space: hidden -> shown, shown -> hidden.
function afterClick(clearNow) { return !clearNow }
