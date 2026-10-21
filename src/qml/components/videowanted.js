.pragma library

// True while some surface shows video: Now Playing (view 5) with its toggle on
// in the full window, or the mini popup open in video mode.
// expanding: the settle before mini goes full size. Main is drawn then, unseen,
// and KWin reveals its last frame, so that frame carries the video.
function wanted(view, miniPlayer, npVideo, miniVisWanted, miniQueueShown, popupVideo, expanding) {
    if ((!miniPlayer || expanding) && view === 5 && npVideo) return true
    if (miniPlayer && miniVisWanted && miniQueueShown && popupVideo) return true
    return false
}
