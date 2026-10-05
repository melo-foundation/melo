.pragma library

// True while some surface shows video: Now Playing (view 5) with its toggle on
// in the full window, or the mini popup open in video mode.
function wanted(view, miniPlayer, npVideo, miniVisWanted, miniQueueShown, popupVideo) {
    if (!miniPlayer && view === 5 && npVideo) return true
    if (miniPlayer && miniVisWanted && miniQueueShown && popupVideo) return true
    return false
}
