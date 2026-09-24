.pragma library

// Ground action on a backing change, split out for testing. A layout swap
// waits until the incoming renderer has drawn; the ground waits too, or the card
// reshapes around the old rows.
//   "snap" — nothing transitioning, or this bar is behind the flip
//   "hold" — a swap is waiting for its renderer
//   "play" — run the crossfade now
function backingAction(swap, quiet, swapPending) {
    if (swap === "none" || quiet === true) return "snap"
    return swapPending === true ? "hold" : "play"
}

// Ground crossfade progress, 0 = old backing, 1 = new. During a swap it
// follows morphIn, which stays 0 while the outgoing bar has the screen, so the
// ground does not run ahead of the content; otherwise it runs its own animation.
function groundProgress(swapping, morphIn, backT) {
    return swapping === true ? morphIn : backT
}

// Bar height during a layout change. The shown renderer switches before the
// incoming one has drawn, so the height is held at fromH until the incoming rows
// arrive; then the Behavior eases on the swap's clock (per Theme.barResize).
function barHeight(swapping, fromH, morphIn, settled) {
    return swapping === true && morphIn <= 0 && fromH > 0 ? fromH : settled
}
